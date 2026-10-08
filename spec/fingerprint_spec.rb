# frozen_string_literal: true

RSpec.describe Empeira::Infrastructure::Definition do
  def definition(yaml = '{}', **options)
    File.write(File.join(@directory, '.empeira.yaml'), yaml)
    context = Empeira::Application.new(project_path: @directory).context
    described_class.new(context: context, **options)
  end

  it 'canonicalizes nested mappings independent of key order' do
    first = { 'b' => { 'z' => 1, 'a' => 2 }, 'a' => ['x'] }
    second = { 'a' => ['x'], 'b' => { 'a' => 2, 'z' => 1 } }
    expect(described_class.fingerprint(first)).to eq(described_class.fingerprint(second))
  end

  it 'ignores YAML representation, comments and unrelated effective configuration' do
    original = definition("runtime: {container_engine: podman}\nnetwork: {egress: []}").fingerprint
    expect(definition("# comment\nnetwork:\n  egress: []\nruntime:\n  container_engine: podman").fingerprint)
      .to eq(original)
    expect(definition('node_defaults: {memory: 4096, os: debian}').fingerprint).to eq(original)
    expect(definition('puppetdb: {enabled: false}').fingerprint).not_to eq(original)
    expect(definition('requirements: {empeira: ">= 0.4"}').fingerprint).to eq(original)
  end

  it 'tracks relevant policy, runtime and infrastructure model changes' do
    original = definition.fingerprint
    expect(definition('proxy: {enabled: true}').fingerprint).not_to eq(original)
    expect(definition('runtime: {container_engine: docker}').fingerprint).not_to eq(original)
    expect(definition('{}', revision: described_class::REVISION + 1).fingerprint).not_to eq(original)
  end

  it 'keeps component fingerprints for future selective reconciliation' do
    value = definition
    expect(value.component_fingerprints).to include('network' => described_class.fingerprint(value.network.to_h))
  end

  it 'does not invalidate infrastructure for an application version change' do
    before = Empeira::Application.new(project_path: @directory, build_info: Empeira::BuildInfo.new(version: '0.3'))
    after = Empeira::Application.new(project_path: @directory, build_info: Empeira::BuildInfo.new(version: '0.4'))
    expect(described_class.new(context: before.context).fingerprint)
      .to eq(described_class.new(context: after.context).fingerprint)
  end
end
