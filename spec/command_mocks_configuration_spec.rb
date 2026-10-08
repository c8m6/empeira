# frozen_string_literal: true

RSpec.describe Empeira::Configuration::CommandMocks do
  let(:entry) { { 'path' => '/usr/bin/oc', 'mock_to' => 'echo', 'exit_code' => 0 } }

  def load_commands(commands)
    File.write(File.join(@directory, '.empeira.yaml'), YAML.dump('mocks' => { 'commands' => commands }))
    Empeira::Configuration::Loader.new(project_path: @directory).load.dig('mocks', 'commands')
  end

  it 'parses the two public examples through the ordinary loader' do
    commands = { 'oc' => entry, 'foo' => { 'path' => '/usr/local/bin/foo',
                                           'mock_to' => '/opt/test/mocks/foo.sh', 'exit_code' => 'passthrough' } }
    expect(load_commands(commands)).to eq(commands)
  end

  it 'keeps command mocks empty when omitted' do
    expect(Empeira::Configuration::Loader.new(project_path: @directory).load.dig('mocks', 'commands')).to eq({})
  end

  it 'deep-merges named entries and fields through fragment and effective validation' do
    defaults = YAML.safe_load_file(Empeira::Configuration::Loader::DEFAULTS)
    defaults['mocks']['commands'] = { 'oc' => entry, 'foo' => entry.merge('path' => '/usr/bin/foo') }
    defaults_path = File.join(@directory, 'defaults.yaml')
    File.write(defaults_path, YAML.dump(defaults))
    File.write(File.join(@directory, '.empeira.yaml'), "mocks:\n  commands:\n    oc:\n      exit_code: 42\n")
    loaded = Empeira::Configuration::Loader.new(project_path: @directory, defaults_path: defaults_path).load
    expect(loaded.dig('mocks',
                      'commands')).to eq(defaults['mocks']['commands'].merge('oc' => entry.merge('exit_code' => 42)))
    expect(defaults.dig('mocks', 'commands', 'oc')).to eq(entry)
  end

  %w[path mock_to exit_code].each do |field|
    it "rejects missing #{field} without supplying a default" do
      expect { load_commands('oc' => entry.except(field)) }
        .to raise_error(Empeira::ConfigurationError, /mocks.commands.oc.#{field} is required/)
    end
  end

  [nil, true, false, '0', 'success', -1, 256, 1.5, [], {}].each do |value|
    it "rejects invalid exit_code #{value.inspect}" do
      expect { load_commands('oc' => entry.merge('exit_code' => value)) }
        .to raise_error(Empeira::ConfigurationError, /mocks.commands.oc.exit_code/)
    end
  end

  [0, 1, 42, 255, 'passthrough'].each do |value|
    it "accepts explicit exit_code #{value.inspect}" do
      expect(load_commands('oc' => entry.merge('exit_code' => value)).dig('oc', 'exit_code')).to eq(value)
    end
  end

  [nil, '', 'usr/bin/oc', '/', '/usr/../bin/oc', '/usr//bin/oc', '/usr/bin/oc/',
   "/usr/bin/oc\n", '/usr/bin/oc;true', '/etc/hosts', '/etc/resolv.conf',
   Empeira::Node::ExternalFact::PATH].each do |value|
    it "rejects unsafe path #{value.inspect}" do
      expect { load_commands('oc' => entry.merge('path' => value)) }
        .to raise_error(Empeira::ConfigurationError, /mocks.commands.oc.path/)
    end
  end

  [nil, '', 'foo.sh', 'echo hello', [], 0, '/opt/../foo'].each do |value|
    it "rejects invalid mock_to #{value.inspect}" do
      expect { load_commands('oc' => entry.merge('mock_to' => value)) }
        .to raise_error(Empeira::ConfigurationError, /mocks.commands.oc.mock_to/)
    end
  end

  [nil, [], 'echo', { 'oc' => [] }, { 'oc' => nil }, { 'oc' => { 'mode' => 'echo' } },
   { '../oc' => {} }, { 1 => {} }].each do |value|
    it "rejects invalid commands structure #{value.inspect}" do
      expect { load_commands(value) }.to raise_error(Empeira::ConfigurationError, /mocks.commands/)
    end
  end

  it 'rejects an invalid mocks namespace through the schema' do
    expect { Empeira::Configuration::Schema.new.validate_fragment!('mocks' => []) }
      .to raise_error(Empeira::ConfigurationError, /mocks must be a mapping/)
  end

  it 'rejects colliding or nested command destinations' do
    ['/usr/bin/oc', '/usr/bin/oc/child'].each do |target|
      expect { load_commands('oc' => entry, 'foo' => entry.merge('path' => target)) }
        .to raise_error(Empeira::ConfigurationError, /mocks.commands.foo.path.*overlaps/)
    end
  end

  it 'retains duplicate-key rejection in the common YAML parser' do
    File.write(File.join(@directory, '.empeira.yaml'), "mocks:\n  commands:\n    oc: {}\n    oc: {}\n")
    expect { Empeira::Configuration::Loader.new(project_path: @directory).load }
      .to raise_error(Empeira::ConfigurationError, /mocks.commands.oc is defined more than once/)
  end
end
