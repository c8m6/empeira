# frozen_string_literal: true

RSpec.describe 'Native image freshness contracts' do
  %w[docker podman].each do |engine|
    context engine do
      let(:context) { Empeira::Application.new(project_path: @directory).context }
      let(:runner) { instance_double(Empeira::Execution::Runner) }
      let(:runtime) { Empeira::Runtime.registry.build(engine, context: context, runner: runner) }
      let(:image) { 'registry.example/team/image:latest' }
      let(:digest) { "sha256:#{'a' * 64}" }
      let(:arm_digest) { "sha256:#{'b' * 64}" }
      let(:calls) { [] }
      let(:images) { {} }
      let(:descriptors) do
        [{ 'digest' => digest, 'platform' => { 'os' => 'linux', 'architecture' => 'amd64' } },
         { 'digest' => arm_digest, 'platform' => { 'os' => 'linux', 'architecture' => 'arm64', 'variant' => 'v8' } }]
      end

      def result(value = '', status: 0, timeout: false)
        Empeira::Execution::Result.new(stdout: value, stderr: '', exit_status: status, timed_out: timeout)
      end

      # rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength -- One synthetic native CLI dispatch for both adapters.
      def native(arguments)
        case arguments.take(2)
        when %w[image inspect]
          images.key?(arguments.last) ? result(JSON.generate([images.fetch(arguments.last)])) : result(status: 1)
        when %w[manifest create] then result('c' * 64)
        when %w[manifest inspect]
          data = if runtime.name == 'docker'
                   descriptors.map do |entry|
                     { 'Descriptor' => entry }
                   end
                 else
                   { 'manifests' => descriptors }
                 end
          result(JSON.generate(data))
        else
          result
        end
      end

      before do
        allow(runtime).to receive(:architecture).and_return('amd64')
        allow(runner).to receive(:run) do |executable, arguments:, **options|
          expect(executable).to eq(engine)
          expect(options.keys - [:timeout]).to be_empty # Native user auth, no Empeira credentials/proxy override.
          calls << [arguments, options]
          native(arguments)
        end
      end

      def local(digest)
        { 'Id' => 'never-a-registry-digest', 'RepoDigests' => [Empeira::Images::Reference.pinned(image, digest)],
          'Architecture' => 'amd64', 'Os' => 'linux' }
      end

      it 'skips an unchanged remote artifact quietly and pulls changed or absent images' do
        images[image] = local(digest)
        expect { expect(runtime.refresh_image(image)).to eq(:unchanged) }.not_to output.to_stdout
        expect(calls.map(&:first).any? { |args| args.first == 'pull' }).to be(false)
        images[image] = local("sha256:#{'d' * 64}")
        allow(runtime).to receive(:remote_digest).and_call_original
        allow(runtime).to receive(:remote_digest).with(image).and_return(arm_digest)
        expect(runtime.refresh_image(image)).to eq(:updated)
        images.clear
        expect(runtime.refresh_image(image)).to eq(:updated)
        expect(calls.map(&:first).count { |args| args == ['pull', image] }).to eq(2)
      end

      %w[amd64 arm64].each do |architecture|
        it "selects the Linux/#{architecture} platform manifest, excluding index/image IDs" do
          allow(runtime).to receive(:architecture).and_return(architecture)
          expect(runtime.remote_digest(image)).to eq(architecture == 'amd64' ? digest : arm_digest)
          expect(calls.select { |args, _| args.first == 'manifest' }.map { |_, options| options[:timeout] })
            .to all(be <= 30)
        end
      end

      it 'resolves a stored index digest to its platform manifest before comparing' do
        index = "sha256:#{'d' * 64}"
        images[image] = local(index)
        expect(runtime.refresh_image(image)).to eq(:unchanged)
        expect(calls.map(&:first).flatten).to include(a_string_including(index))
        expect(calls.map(&:first).any? { |args| args.first == 'pull' }).to be(false)
      end

      context 'with an immutable multi-architecture reference' do
        let(:image) { "registry.example/team/image@sha256:#{'d' * 64}" }

        it 'checks the exact index and skips unchanged local content without following a software tag' do
          images[image] = local("sha256:#{'d' * 64}")
          runtime.with_image_updates { expect(runtime.refresh_image(image)).to eq(:unchanged) }
          manifest_calls = calls.map(&:first).select { |args| args.first == 'manifest' }
          expect(manifest_calls.flatten).to include(a_string_including(image))
          expect(manifest_calls.flatten).not_to include('registry.example/team/image:latest')
          expect(calls.map(&:first)).not_to include(array_including('pull'))
        end

        it 'acquires a missing pinned artifact using only its exact reference' do
          runtime.ensure_image(image)
          expect(calls.last.first).to eq(['pull', image])
          expect(calls.map(&:first)).not_to include(array_including('manifest'))
        end
      end

      it 'fails metadata timeouts with the image reference and no full-pull fallback' do
        allow(runner).to receive(:run).and_return(result(status: nil, timeout: true))
        expect(runtime).not_to receive(:build_image)
        expect(runner).not_to receive(:run).with(engine, arguments: ['pull', image], timeout: 600)
        expect do
          runtime.refresh_image(image)
        end.to raise_error(Empeira::Providers::ExecutionError, /#{Regexp.escape(image)}.*timeout/m)
      end

      it 'uses existing images during up without metadata and pulls only missing remote images' do
        images[image] = local(digest)
        expect(runtime).not_to receive(:remote_digest)
        runtime.ensure_image(image)
        expect(calls.map(&:first)).to eq([['image', 'inspect', image]])
        images.clear
        runtime.ensure_image(image)
        expect(calls.last.first).to eq(['pull', image])
      end

      it 'skips matching recipe, resources and bases; rebuilds only after a changed input' do
        recipe = "ARG EMPEIRA_BASE_ONE=#{image}\nFROM ${EMPEIRA_BASE_ONE}\nFROM scratch\n"
        bases = { 'EMPEIRA_BASE_ONE' => { 'reference' => image, 'digest' => digest } }
        labels = { 'io.empeira.recipe' => Digest::SHA256.hexdigest(recipe),
                   'io.empeira.build-inputs' => Empeira::Infrastructure::Definition.fingerprint({}),
                   'io.empeira.base-inputs' => JSON.generate(bases),
                   'io.empeira.base-fingerprint' => Empeira::Infrastructure::Definition.fingerprint(bases) }
        images['localhost/empeira-test:1'] = { 'Config' => { 'Labels' => labels } }
        expect(runtime.refresh_image('localhost/empeira-test:1', recipe: recipe)).to eq(:unchanged)
        expect(calls.map(&:first).any? { |args| args.first == 'build' }).to be(false)
        allow(runtime).to receive(:remote_digest).and_call_original
        allow(runtime).to receive(:remote_digest).with(image).and_return(arm_digest)
        expect(runtime.refresh_image('localhost/empeira-test:1', recipe: recipe)).to eq(:updated)
        build = calls.map(&:first).find { |args| args.first == 'build' }
        expect(build).to include('--pull', "EMPEIRA_BASE_ONE=registry.example/team/image@#{arm_digest}")
        expect(build).not_to include('--no-cache')
        expect(build).to include(a_string_starting_with('io.empeira.base-fingerprint='))
        expect(File).not_to exist(build.last)
        allow(runtime).to receive(:remote_digest).with(image).and_return(digest)
        expect(runtime.refresh_image('localhost/empeira-test:1', recipe: recipe, files: { 'extra.txt' => 'changed' }))
          .to eq(:updated)
      end

      it 'builds a missing recipe from local bases without remote freshness checks' do
        recipe = "ARG EMPEIRA_BASE_ONE=#{image}\nFROM ${EMPEIRA_BASE_ONE}\n"
        images[image] = local(digest)
        expect(runtime).not_to receive(:remote_digest)
        runtime.ensure_image('localhost/empeira-test:1', recipe: recipe)
        build = calls.map(&:first).find { |args| args.first == 'build' }
        expect(build).not_to include('--pull')
        expect(build).to include("EMPEIRA_BASE_ONE=registry.example/team/image@#{digest}")
        images['localhost/empeira-test:1'] = { 'Config' => { 'Labels' => { 'io.empeira.recipe' => Digest::SHA256.hexdigest(recipe) } } }
        calls.clear
        runtime.ensure_image('localhost/empeira-test:1', recipe: recipe)
        expect(calls.size).to eq(1)
      end

      it 'builds new recipe identities and records multiple sorted bases while ignoring scratch' do
        recipe = "ARG EMPEIRA_BASE_TWO=#{image}\nARG EMPEIRA_BASE_ONE=ghcr.io/example/base:1\n" \
                 "FROM ${EMPEIRA_BASE_ONE} AS first\nFROM ${EMPEIRA_BASE_TWO}\nFROM scratch\n"
        revised = "#{recipe}LABEL revision=2\n"
        [recipe, revised].each do |source|
          reference = Empeira::Images::Configuration.local_image(source)
          expect(runtime.refresh_image(reference, recipe: source)).to eq(:updated)
        end
        builds = calls.map(&:first).select { |args| args.first == 'build' }
        expect(builds.size).to eq(2)
        labels = builds.map { |args| args.find { |value| value.start_with?('io.empeira.base-fingerprint=') } }
        expect(labels.uniq.size).to eq(1)
        recorded = JSON.parse(builds.first.find do |value|
          value.start_with?('io.empeira.base-inputs=')
        end.split('=', 2).last)
        expect(recorded.keys).to eq(%w[EMPEIRA_BASE_ONE EMPEIRA_BASE_TWO])
        expect(calls.map(&:first).flatten).not_to include('scratch')
      end

      it 'rejects malformed or ambiguous remote platform metadata without pulling' do
        descriptors.first['platform'] = 'malformed'
        expect { runtime.refresh_image(image) }.to raise_error(Empeira::Providers::ExecutionError, /manifest digest/)
        expect(calls.map(&:first).any? { |args| args.first == 'pull' }).to be(false)
        expect(calls.map(&:first)).to include(['manifest', 'rm', 'c' * 64]) if engine == 'podman'
      end
    end
  end
end
