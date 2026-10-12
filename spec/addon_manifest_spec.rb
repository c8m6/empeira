# frozen_string_literal: true

RSpec.describe Empeira::Addons::Manifest do
  let(:root) { Pathname(@directory).join('addon') }
  let(:manifest) { root.join('empeira-addon.yaml') }
  let(:data) { YAML.safe_load(manifest.read) }

  before do
    FileUtils.cp_r(File.expand_path('fixtures/addon', __dir__), root)
    root.join('bin/example').chmod(0o755)
  end

  def load_manifest
    described_class.new(name: 'example', path: root)
  end

  def change(**values)
    manifest.write(YAML.dump(data.merge(values.transform_keys(&:to_s))))
  end

  it 'loads and freezes the complete declarative schema' do
    expect(load_manifest.data.fetch('schema')).to eq(1)
    expect(load_manifest.executable).to eq(root.join('bin/example'))
    expect { load_manifest.data['commands'].clear }.to raise_error(FrozenError)
  end

  [2, nil, '1', 1.0].each do |version|
    it "rejects schema #{version.inspect}" do
      change(schema: version)
      expect { load_manifest }.to raise_error(Empeira::Addons::Error, /Addon example: unsupported manifest schema/)
    end
  end

  %w[schema description executable commands].each do |key|
    it "requires #{key}" do
      manifest.write(YAML.dump(data.reject { |field, _| field == key }))
      expect { load_manifest }.to raise_error(Empeira::Addons::Error, /missing or unsupported fields/)
    end
  end

  ["schema: [\n", "schema: 1\nschema: 2", '--- !ruby/object:Object {}', "a: &a {}\nb: *a"].each do |text|
    it 'rejects unsafe or malformed YAML without displaying content' do
      manifest.write(text)
      expect { load_manifest }.to raise_error(Empeira::Addons::Error, /manifest.*YAML/)
    end
  end

  ['/bin/sh', '../outside', 'bin/../../outside', './bin/example', "bin/ex\0ample"].each do |path|
    it "rejects escaping path #{path}" do
      change(executable: path)
      expect { load_manifest }.to raise_error(Empeira::Addons::Error, /relative path without traversal/)
    end
  end

  it 'reports missing and nonexecutable entrypoints with OS exit conventions' do
    root.join('bin/example').chmod(0o644)
    expect { load_manifest }.to raise_error(Empeira::Addons::Error) { |e| expect(e.exit_status).to eq(126) }
    root.join('bin/example').delete
    expect { load_manifest }.to raise_error(Empeira::Addons::Error) { |e| expect(e.exit_status).to eq(127) }
  end

  it 'rejects executable and manifest symlinks outside the repository' do
    root.join('bin/example').delete
    File.symlink(RbConfig.ruby, root.join('bin/example'))
    expect { load_manifest }.to raise_error(Empeira::Addons::Error, /escapes/)
    FileUtils.mv(manifest, root.parent.join('outside.yaml'))
    File.symlink('../outside.yaml', manifest)
    expect { load_manifest }.to raise_error(Empeira::Addons::Error, /escapes/)
  end

  it 'allows contained executable symlinks' do
    FileUtils.mv(root.join('bin/example'), root.join('bin/real'))
    File.symlink('real', root.join('bin/example'))
    expect(load_manifest.executable).to eq(root.join('bin/real'))
  end

  it 'rejects missing manifests' do
    manifest.delete
    expect { load_manifest }.to raise_error(Empeira::Addons::Error, /manifest is missing/)
  end

  ['dynamic', 'shell', nil].each do |type|
    it "rejects completion type #{type.inspect}" do
      values = data
      values['commands']['echo']['arguments'][0]['completion'] = type
      manifest.write(YAML.dump(values))
      expect { load_manifest }.to raise_error(Empeira::Addons::Error, /completion type/)
    end
  end

  it 'requires enum values and rejects undeclared command fields' do
    values = data
    values['commands']['choose']['arguments'][0].delete('values')
    manifest.write(YAML.dump(values))
    expect { load_manifest }.to raise_error(Empeira::Addons::Error, /requires an array/)
    values['commands']['choose'] = { 'description' => 'example', 'executable' => 'bin/other' }
    manifest.write(YAML.dump(values))
    expect { load_manifest }.to raise_error(Empeira::Addons::Error, /unsupported fields/)
  end
end
