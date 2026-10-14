# frozen_string_literal: true

RSpec.describe Empeira::Addons::Environment do
  let(:context) { Empeira::Application.new(project_path: @directory).context }

  def export(config, inherited: {})
    changed = context.with(configuration: config)
    described_class.new(context: changed, name: 'example', ref: 'v1', path: Pathname(@directory),
                        inherited: inherited).export
  end

  it 'flattens scalar types, nested mappings and all array shapes without a configuration file' do
    result = export({ 'text' => 'value with spaces', 'int' => 3, 'float' => 1.25, 'yes' => true, 'no' => false,
                      'empty' => '', 'absent' => nil, 'hash' => { 'key-name' => 'x' }, 'array' => %w[one two],
                      'zero' => [], 'mounts' => [{ 'source' => '/a', 'readonly' => false }],
                      'nested' => [[1, nil], []] })
    expect(result).to include(
      'EMPEIRA_CONFIG_TEXT' => 'value with spaces', 'EMPEIRA_CONFIG_INT' => '3', 'EMPEIRA_CONFIG_FLOAT' => '1.25',
      'EMPEIRA_CONFIG_YES' => 'true', 'EMPEIRA_CONFIG_NO' => 'false', 'EMPEIRA_CONFIG_EMPTY' => '',
      'EMPEIRA_CONFIG_HASH_KEY_NAME' => 'x', 'EMPEIRA_CONFIG_ARRAY_COUNT' => '2', 'EMPEIRA_CONFIG_ARRAY_0' => 'one',
      'EMPEIRA_CONFIG_ARRAY_1' => 'two', 'EMPEIRA_CONFIG_ZERO_COUNT' => '0', 'EMPEIRA_CONFIG_MOUNTS_COUNT' => '1',
      'EMPEIRA_CONFIG_MOUNTS_0_SOURCE' => '/a', 'EMPEIRA_CONFIG_MOUNTS_0_READONLY' => 'false',
      'EMPEIRA_CONFIG_NESTED_COUNT' => '2', 'EMPEIRA_CONFIG_NESTED_0_COUNT' => '2',
      'EMPEIRA_CONFIG_NESTED_0_0' => '1', 'EMPEIRA_CONFIG_NESTED_1_COUNT' => '0'
    )
    expect(result).not_to have_key('EMPEIRA_CONFIG_ABSENT')
    expect(result).not_to have_key('EMPEIRA_CONFIG_NESTED_0_1')
  end

  it 'exports the effective deep merge and absolute runtime context' do
    File.write(File.join(@directory, '.empeira.yaml'), 'proxy: {enabled: false, global: [example.org]}')
    result = export(context.configuration)
    expect(result).to include('EMPEIRA_CONFIG_PROXY_ENABLED' => 'false',
                              'EMPEIRA_CONFIG_PROXY_GLOBAL_0' => 'example.org',
                              'EMPEIRA_CONFIG_NODE_DEFAULTS_CPUS' => '2', 'EMPEIRA_ADDON_API_VERSION' => '1',
                              'EMPEIRA_ADDON_NAME' => 'example', 'EMPEIRA_ADDON_VERSION' => 'v1',
                              'EMPEIRA_ADDON_PATH' => @directory, 'EMPEIRA_WORKSPACE' => @directory,
                              'EMPEIRA_CONTROL_REPO' => @directory, 'EMPEIRA_VERSION' => 'development')
  end

  it 'exports only the selected addon config without leaking other addon settings' do
    config = { 'addons' => {
      'example' => { 'git' => 'https://example.invalid/one.git', 'ref' => 'main',
                     'config' => { 'auto_build' => true, 'paths' => %w[control hiera],
                                   'nested' => { 'timeout' => 15, 'missing' => nil } } },
      'other' => { 'git' => 'https://example.invalid/two.git', 'ref' => 'main',
                   'config' => { 'secret' => 'private-value' } }
    } }
    result = export(config, inherited: { 'EMPEIRA_ADDON_CONFIG_STALE' => 'forged' })
    expect(result).to include('EMPEIRA_ADDON_CONFIG_AUTO_BUILD' => 'true',
                              'EMPEIRA_ADDON_CONFIG_PATHS_COUNT' => '2',
                              'EMPEIRA_ADDON_CONFIG_PATHS_0' => 'control',
                              'EMPEIRA_ADDON_CONFIG_PATHS_1' => 'hiera',
                              'EMPEIRA_ADDON_CONFIG_NESTED_TIMEOUT' => '15')
    expect(result).not_to have_key('EMPEIRA_ADDON_CONFIG_NESTED_MISSING')
    expect(result).to have_key('EMPEIRA_ADDON_CONFIG_STALE')
    expect(result['EMPEIRA_ADDON_CONFIG_STALE']).to be_nil
    expect(result.keys.grep(/EMPEIRA_CONFIG_ADDONS_.*CONFIG/)).to be_empty
    expect(result.values).not_to include('private-value')
  end

  it 'removes inherited reserved names, including absent and sensitive fields, without changing user variables' do
    inherited = { 'USER_VALUE' => 'preserved', 'EMPEIRA_ADDON_NAME' => 'forged', 'EMPEIRA_CONFIG_ABSENT' => 'stale',
                  'EMPEIRA_CONFIG_VM_CONSOLE_ROOT_PASSWORD' => 'secret', 'EMPEIRA_SPOOFED' => 'forged' }
    result = export(context.configuration, inherited: inherited)
    expect(inherited.merge(result).compact).to include('USER_VALUE' => 'preserved', 'EMPEIRA_ADDON_NAME' => 'example')
    expect(result.values).not_to include('secret', 'forged', 'stale')
    expect(result['EMPEIRA_CONFIG_VM_CONSOLE_ROOT_PASSWORD']).to be_nil
    expect(inherited['EMPEIRA_ADDON_NAME']).to eq('forged')
  end

  it 'excludes sensitive schema fields and arbitrary content regardless of nested key names' do
    service = { 'name' => 'sample', 'environment' => { 'ordinary' => 'hidden' }, 'command' => ['hidden'],
                'configuration' => { 'target' => '/etc/a', 'content' => { 'a' => 'hidden' } } }
    config = { 'vm' => { 'console' => { 'root_password' => 'hidden' } }, 'eyaml' => { 'private_key' => 'hidden' },
               'browser' => { 'start_url' => 'hidden' },
               'containers' => { 'additional' => [service] } }
    result = export(config)
    expect(result.values).not_to include('hidden')
    expect(result).to include('EMPEIRA_CONFIG_CONTAINERS_ADDITIONAL_0_NAME' => 'sample',
                              'EMPEIRA_CONFIG_CONTAINERS_ADDITIONAL_0_CONFIGURATION_TARGET' => '/etc/a')
  end

  it 'omits unavailable context without creating workspace infrastructure' do
    absent = context.with(project: nil, workspace: nil)
    result = described_class.new(context: absent, name: 'example', ref: 'v1', path: Pathname(@directory)).export
    expect(result).not_to have_key('EMPEIRA_WORKSPACE')
    expect(result).not_to have_key('EMPEIRA_CONTROL_REPO')
  end

  it 'rejects oversized entries and combined environment/argv without disclosing values' do
    expect { export({ 'large' => 'sensitive' * 30_000 }) }.to raise_error(Empeira::Addons::Error) do |error|
      expect(error.message).to include('size limit')
      expect(error.full_message).not_to include('sensitive')
    end
    allow(Etc).to receive(:sysconf).with(Etc::SC_ARG_MAX).and_return(32_768)
    expect do
      export({}, inherited: { 'USER_VALUE' => 'a' * 20_000 })
    end.to raise_error(Empeira::Addons::Error, /size limit/)
  end

  it 'rejects null bytes without logging configuration content' do
    expect { export({ 'field' => "hidden\0value" }) }.to raise_error(Empeira::Addons::Error) do |error|
      expect(error.message).to include('null byte')
      expect(error.full_message).not_to include('hidden')
    end
  end
end
