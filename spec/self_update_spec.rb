# frozen_string_literal: true

RSpec.describe 'RubyGems self-update' do
  let(:runner) { instance_double(Empeira::Execution::Runner) }
  let(:service) { Empeira::Updates::Service.new(runner: runner) }
  let(:root) { File.expand_path('..', __dir__) }
  let(:spec) do
    Gem::Specification.new do |gem|
      gem.name = 'empeira'
      gem.version = '1.0'
    end
  end
  let(:environment) { { 'GEM_HOME' => spec.base_dir, 'GEM_PATH' => spec.base_dir } }
  let(:success) { Empeira::Execution::Result.new(stdout: '', stderr: '', exit_status: 0, timed_out: false) }

  around do |example|
    original = ENV.delete('BUNDLE_GEMFILE')
    example.run
  ensure
    ENV['BUNDLE_GEMFILE'] = original if original
  end

  before do
    hide_const('Bundler')
    allow(spec).to receive_messages(base_dir: File.join(@directory, 'gem-home'), full_gem_path: root)
    FileUtils.mkdir_p(File.dirname(spec.spec_file))
    File.write(spec.spec_file, '')
    allow(Gem.loaded_specs).to receive(:[]).and_call_original
    allow(Gem.loaded_specs).to receive(:[]).with('empeira').and_return(spec)
  end

  it 'updates through the current Ruby and verifies a newer stable version in the same gem repository' do
    expect(runner).to receive(:run).with(
      RbConfig.ruby,
      arguments: array_including(File.join(RbConfig::CONFIG.fetch('bindir'), 'gem'), 'update', 'empeira',
                                 '--norc', '--no-prerelease', '--install-dir', spec.base_dir,
                                 '--bindir', Gem.bindir(spec.base_dir), '--source', Gem::DEFAULT_HOST),
      environment: environment
    ).ordered.and_return(success)
    expect(runner).to receive(:run).with(
      RbConfig.ruby,
      arguments: ['-rrubygems', '-e', Empeira::Updates::Service::INSTALLED_VERSION, spec.base_dir],
      environment: environment
    ).ordered.and_return(success.with(stdout: "1.1\n"))
    expect(service.self_update).to eq([spec, Gem::Version.new('1.1')])
  end

  it 'recognizes an already current version from the fresh installed-version query' do
    allow(runner).to receive(:run).and_return(success, success.with(stdout: "1.0\n"))
    expect(service.self_update).to eq([spec, Gem::Version.new('1.0')])
  end

  it 'preserves native RubyGems failure details, including insufficient permissions, without querying success' do
    failure = success.with(stdout: 'Updating installed gems', stderr: 'ERROR: permission denied', exit_status: 1)
    expect(runner).to receive(:run).once.and_return(failure)
    expect { service.self_update }.to raise_error(Empeira::Error, /Updating installed gems.*ERROR: permission denied/m)
  end

  it 'rejects checkout and Bundler environments before invoking RubyGems' do
    expect(runner).not_to receive(:run)
    allow(Gem.loaded_specs).to receive(:[]).with('empeira').and_return(nil)
    expect { service.self_update }.to raise_error(Empeira::UnavailableFeature, /regular RubyGems installation/)
    allow(Gem.loaded_specs).to receive(:[]).with('empeira').and_return(spec)
    allow(spec).to receive(:full_gem_path).and_return(@directory)
    expect { service.self_update }.to raise_error(Empeira::UnavailableFeature, /regular RubyGems installation/)
    allow(spec).to receive(:full_gem_path).and_return(root)
    stub_const('Bundler', Module.new)
    expect { service.self_update }.to raise_error(Empeira::UnavailableFeature, /Bundler/)
  end

  it 'runs all updates in order using the verified version in fresh Ruby processes' do
    expect(service).to receive(:self_update).ordered.and_return([spec, Gem::Version.new('1.1')])
    %w[images modules].each do |artifact|
      expect(runner).to receive(:stream).with(
        RbConfig.ruby,
        arguments: ['-rrubygems', '-e', 'load Gem.activate_bin_path("empeira", "empeira", ARGV.shift)',
                    '1.1', 'update', artifact],
        environment: environment
      ).ordered.and_return(success)
    end
    service.update('all')
  end

  it 'stops all updates when RubyGems fails and preserves its exit code' do
    expect(runner).to receive(:run).once.and_return(success.with(stderr: 'update failed', exit_status: 7))
    expect(runner).not_to receive(:stream)
    expect { service.update('all') }.to raise_error(Empeira::Updates::CommandFailed) { |error|
      expect(error.exit_status).to eq(7)
    }
  end

  it 'stops on the first failed artifact update and preserves that exit code' do
    %w[images modules].each do |failed|
      allow(service).to receive(:self_update).and_return([spec, Gem::Version.new('1.1')])
      expect(runner).to receive(:stream).ordered.and_return(success) if failed == 'modules'
      expect(runner).to receive(:stream).ordered.and_return(success.with(exit_status: 9))
      expect { service.update('all') }.to raise_error(Empeira::Updates::CommandFailed, /#{failed}/) { |error|
        expect(error.exit_status).to eq(9)
      }
    end
  end

  it 'fails when RubyGems exits successfully but the installed version is missing, invalid or older' do
    ['', 'unverifiable', '0.9', '1.2.pre'].each do |version|
      allow(runner).to receive(:run).and_return(success, success.with(stdout: version))
      expect { service.self_update }.to raise_error(Empeira::Error, /installed Empeira version could not be verified/)
    end
    allow(runner).to receive(:run).and_return(success, success.with(stderr: 'missing gem', exit_status: 1))
    expect { service.self_update }.to raise_error(Empeira::Error, /missing gem/)
  end
end
