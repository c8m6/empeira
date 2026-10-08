# frozen_string_literal: true

require_relative '../support/image_registry'

RSpec.describe 'Native image freshness with a synthetic registry', :integration do
  Empeira::Runtime.registry.names.each do |engine|
    context engine do
      let(:app) { Empeira::Application.new(project_path: @directory) }
      let(:runtime) { Empeira::Runtime.registry.build(engine, context: app.context, runner: app.runner) }

      before do
        skip 'Set EMPEIRA_INTEGRATION=images for real native manifest/pull/build checks' unless
          ENV['EMPEIRA_INTEGRATION'] == 'images'

        runtime.check_available!
        @fixture = ImageRegistryFixture.new(runtime: runtime, runner: app.runner, directory: @directory).start
        allow(app.runner).to receive(:run).and_wrap_original do |method, executable, arguments:, **options|
          resolved = @fixture.arguments(arguments)
          method.call(executable, arguments: resolved, **options, environment: @fixture.environment)
        end
      end

      after { @fixture&.close }

      it 'acquires missing artifacts, skips an unchanged catalog, then pulls and rebuilds changed bases' do
        configured = { 'repository' => 'library/empeira-fixture', 'tag' => 'latest' }
        image = Empeira::Images::Configuration.reference(configured, registry: @fixture.host)
        expect(image).to eq(@fixture.image)
        explicit = { 'repository' => 'registry.example/team/view', 'tag' => '1' }
        expect(Empeira::Images::Configuration.reference(explicit, registry: @fixture.host))
          .to eq('registry.example/team/view:1')
        @fixture.publish('first revision')
        @fixture.forget_tag
        expect(runtime.refresh_image(image)).to eq(:updated)
        initial = runtime.image_id(image)
        recipe = "ARG EMPEIRA_BASE_TEST=#{image}\nFROM ${EMPEIRA_BASE_TEST}\nLABEL fixture=recipe\n"
        built = "localhost/empeira-freshness:#{SecureRandom.hex(16)}"
        runtime.ensure_image(built, recipe: recipe)
        first_build = runtime.image_id(built)
        @fixture.calls.clear
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        runtime.with_image_updates do
          expect(runtime.refresh_image(image)).to eq(:unchanged)
          expect(runtime.refresh_image(built, recipe: recipe)).to eq(:unchanged)
        end
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        expect(@fixture.counts).to include(pulls: 0, builds: 0)
        puts "#{engine} unchanged 2-artifact catalog: #{elapsed.round(3)}s #{@fixture.counts}"
        @fixture.publish('second revision')
        @fixture.restore(initial)
        @fixture.calls.clear
        expect(runtime.refresh_image(image)).to eq(:updated)
        expect(runtime.refresh_image(built, recipe: recipe)).to eq(:updated)
        expect(runtime.image_id(built)).not_to eq(first_build)
        expect(@fixture.counts).to include(pulls: 1, builds: 1)
        @fixture.calls.clear
        runtime.ensure_image(image)
        runtime.ensure_image(built, recipe: recipe)
        expect(@fixture.counts).to eq(pulls: 0, builds: 0, metadata: 0)
      ensure
        runtime.update_command(['image', 'rm', built], operation: 'synthetic recipe cleanup') if built
      end
    end
  end
end

RSpec.describe 'Native immutable default image refresh', :integration do
  Empeira::Runtime.registry.names.each do |engine|
    context engine do
      it 'reuses exact default index pins without pulling or following descriptive tags' do
        skip 'Set EMPEIRA_INTEGRATION=images for native immutable image checks' unless
          ENV['EMPEIRA_INTEGRATION'] == 'images'

        app = Empeira::Application.new(project_path: @directory)
        runtime = Empeira::Runtime.registry.build(engine, context: app.context, runner: app.runner)
        runtime.check_available!
        images = %w[server puppetdb postgres].map do |component|
          Empeira::Images::Configuration.reference(app.context.configuration.dig('images', component))
        end
        images.each { |image| runtime.ensure_image(image) }
        previous = images.to_h { |image| [image, runtime.image_id(image)] }
        calls = []
        allow(app.runner).to receive(:run).and_wrap_original do |method, executable, arguments:, **options|
          calls << arguments if executable == engine
          method.call(executable, arguments: arguments, **options)
        end
        runtime.with_image_updates do
          images.each { |image| expect(runtime.refresh_image(image)).to eq(:unchanged) }
        end
        expect(calls).not_to include(array_including('pull'))
        expect(images.to_h { |image| [image, runtime.image_id(image)] }).to eq(previous)
        calls.clear
        images.each { |image| runtime.ensure_image(image) }
        expect(calls).not_to include(array_including('pull'), array_including('manifest'))
      end
    end
  end
end
