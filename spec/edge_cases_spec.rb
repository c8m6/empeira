# frozen_string_literal: true

RSpec.describe 'Foundation boundary cases' do
  def config_text(text)
    File.write(File.join(@directory, '.empeira.yaml'), text)
    Empeira::Configuration::Loader.new(project_path: @directory).load
  end

  it 'rejects repeated configuration keys with the full path' do
    expect { config_text("node_defaults:\n  cpus: 0\n  cpus: 2\n") }
      .to raise_error(Empeira::ConfigurationError, /node_defaults.cpus is defined more than once/)
  end

  it 'rejects additional YAML documents instead of silently ignoring them' do
    expect { config_text("version: 1\n---\nmisspelled: true\n") }
      .to raise_error(Empeira::ConfigurationError, /exactly one YAML document/)
  end

  it 'does not treat an unreadable configuration symlink as absent' do
    File.unlink(File.join(@directory, '.empeira.yaml'))
    File.symlink(File.join(@directory, 'missing'), File.join(@directory, '.empeira.yaml'))
    expect { Empeira::Configuration::Loader.new(project_path: @directory).load }
      .to raise_error(Empeira::ConfigurationError, /missing marker/)
  end

  it 'rejects malformed hostnames before provider dispatch' do
    config = Empeira::Configuration::Loader.new(project_path: @directory).load
    ['', '-host', 'host.', 'host..test', "#{'a' * 64}.test", 'host/name'].each do |hostname|
      expect { Empeira::Node::RunRequest.from_config(hostname: hostname, provider: 'vm', config: config) }
        .to raise_error(Empeira::Error, /hostname/)
    end
  end

  it 'validates process input types without echoing their values' do
    runner = Empeira::Execution::Runner.new
    [{ arguments: 'synthetic-secret' }, { arguments: ["bad\0value"] },
     { environment: { 'TOKEN' => 123 } }, { environment: { 'BAD=NAME' => 'synthetic-secret' } }].each do |options|
      expect { runner.run(RbConfig.ruby, **options) }
        .to raise_error(Empeira::ExecutionError) { |error| expect(error.message).not_to include('synthetic-secret') }
    end
  end

  it 'does not treat a signal exit as success' do
    result = Empeira::Execution::Result.new(stdout: '', stderr: '', exit_status: nil, timed_out: false)
    expect(result).not_to be_success
  end
end
