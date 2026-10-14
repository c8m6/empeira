# frozen_string_literal: true

RSpec.describe Empeira::Configuration::Addons do
  let(:git) { 'https://example.invalid/addon.git' }

  def load_config(defaults_path: Empeira::Configuration::Loader::DEFAULTS)
    Empeira::Configuration::Loader.new(project_path: @directory, defaults_path: defaults_path).load
  end

  def write_config(value)
    File.write(File.join(@directory, '.empeira.yaml'), YAML.dump('addons' => value))
  end

  it 'defaults to an empty mapping and merges project references with default sources and other addons' do
    expect(load_config.fetch('addons')).to eq({})
    defaults = load_config.merge('addons' => { 'one' => { 'git' => git, 'ref' => 'main' } })
    file = File.join(@directory, 'defaults.yaml')
    File.write(file, YAML.dump(defaults))
    write_config('one' => { 'ref' => 'v2' }, 'git-hooks' => { 'git' => git, 'ref' => 'HEAD' })
    expect(load_config(defaults_path: file).fetch('addons')).to eq(
      'one' => { 'git' => git, 'ref' => 'v2' }, 'git-hooks' => { 'git' => git, 'ref' => 'HEAD' }
    )
  end

  it 'accepts optional nested addon config and deep-merges it with project settings' do
    defaults = load_config.merge(
      'addons' => { 'example' => { 'git' => git, 'ref' => 'main',
                                  'config' => { 'options' => { 'enabled' => true }, 'paths' => %w[old] } } }
    )
    file = File.join(@directory, 'defaults.yaml')
    File.write(file, YAML.dump(defaults))
    write_config('example' => { 'config' => { 'options' => { 'timeout' => 5 }, 'paths' => %w[new] } })
    expect(load_config(defaults_path: file).dig('addons', 'example', 'config')).to eq(
      'options' => { 'enabled' => true, 'timeout' => 5 }, 'paths' => %w[new]
    )
  end

  it 'rejects invalid addon config without printing its values' do
    [nil, 'hidden', [], { 'Bad-Key' => 'hidden' }, { 'nested' => { 'invalid.key' => 'hidden' } }].each do |value|
      write_config('example' => { 'git' => git, 'ref' => 'main', 'config' => value })
      expect { load_config }.to raise_error(Empeira::ConfigurationError) do |error|
        expect(error.message).to include('addons.example.config')
        expect(error.message).not_to include('hidden')
      end
    end
  end

  [{}, { 'ref' => 'main' }, { 'git' => 'https://example.invalid/a' }].each do |entry|
    it "rejects missing effective fields #{entry.keys}" do
      write_config('example' => entry)
      expect { load_config }.to raise_error(Empeira::ConfigurationError, /addons.example.*required/)
    end
  end

  [nil, '', false, 12, 'ext::command', '-host:repo', 'file:///tmp/source',
   'https://user:password@example.invalid/a'].each do |git|
    it "rejects invalid source #{git.inspect} without printing the value" do
      write_config('example' => { 'git' => git, 'ref' => 'main' })
      expect { load_config }.to raise_error(Empeira::ConfigurationError, /addons.example.git must/)
    end
  end

  [nil, '', false, 1, [], "main\n", '-option'].each do |ref|
    it "rejects invalid reference #{ref.inspect}" do
      write_config('example' => { 'git' => git, 'ref' => ref })
      expect { load_config }.to raise_error(Empeira::ConfigurationError, /addons.example.ref must/)
    end
  end

  it 'does not accept executable or addon functionality in configuration' do
    write_config('example' => { 'git' => git, 'ref' => 'main', 'executable' => 'bin/run' })
    expect { load_config }.to raise_error(Empeira::ConfigurationError, /only git, ref and config/)
  end

  it 'retains the user preference restrictions and resolves each invocation afresh' do
    write_config('example' => { 'git' => git, 'ref' => 'main' })
    expect(load_config.dig('addons', 'example', 'ref')).to eq('main')
    write_config('example' => { 'git' => git, 'ref' => 'v1' })
    expect(load_config.dig('addons', 'example', 'ref')).to eq('v1')
    File.write(File.join(@directory, 'user-home/.empeira.yaml'), YAML.dump('addons' => {}))
    expect { load_config }.to raise_error(Empeira::ConfigurationError)
  end

  it 'does not change workspace infrastructure fingerprints when only addon refs change' do
    application = Empeira::Application.new(project_path: @directory)
    original = Empeira::Infrastructure::Definition.new(context: application.context).component_fingerprints
    write_config('example' => { 'git' => git, 'ref' => 'v2' })
    updated = Empeira::Application.new(project_path: @directory)
    expect(Empeira::Infrastructure::Definition.new(context: updated.context).component_fingerprints).to eq(original)
  end
end
