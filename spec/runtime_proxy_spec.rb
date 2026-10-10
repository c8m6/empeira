# frozen_string_literal: true

require_relative '../resources/nodes/runtime_proxy'
require_relative 'support/runtime_proxy_guest'

RSpec.describe Empeira::Node::RuntimeProxy do
  include RuntimeProxyFixture

  let(:context) { Empeira::Application.new(project_path: @directory).context }

  after { cleanup_runtime_proxy_guests }

  it 'persists intent and reconciles enabled and disabled policy idempotently' do
    File.write(File.join(@directory, '.empeira.yaml'), YAML.dump('proxy' => { 'enabled' => true }))
    record = {}
    snapshots = []
    execute = ->(arguments) { runtime_proxy_result(arguments, 'synthetic-node') }
    persist = -> { snapshots << Marshal.load(Marshal.dump(record)) }
    proxy = described_class.new(context: context, record: record, execute: execute, persist: persist)
    expect(proxy.reconcile).to be(true)
    expect(snapshots.first.fetch('runtime_proxy')).to have_key('previous')
    expect(described_class.valid_inventory?(record.fetch('runtime_proxy'))).to be(true)
    expect(proxy.reconcile).to be(false)
    File.write(File.join(@directory, '.empeira.yaml'), YAML.dump('proxy' => { 'enabled' => false }))
    disabled = context.with(configuration: Empeira::Configuration::Loader.new(project_path: @directory).load)
    proxy = described_class.new(context: disabled, record: record, execute: execute, persist: persist)
    expect(proxy.reconcile).to be(true)
    expect(proxy.reconcile).to be(false)
    expect(record.fetch('runtime_proxy')).to eq('current' => nil)
  end

  it 'overrides stale creation-time variables when normal proxy access is disabled' do
    command = described_class.command(context, %w[sh -c env])
    result = Empeira::Execution::Runner.new.run(command.first, arguments: command.drop(1),
                                                               environment: { 'http_proxy' => 'stale' })
    expect(result.stdout.lines).to include("http_proxy=\n", "HTTP_PROXY=\n", "NO_PROXY=\n")
  end

  it 'preserves internal and explicit direct-egress bypasses in all managed process environments' do
    File.write(File.join(@directory, '.empeira.yaml'),
               YAML.dump('proxy' => { 'enabled' => true },
                         'network' => { 'egress' => [{ 'host' => 'direct.example', 'ports' => [80] },
                                                     { 'ip' => '192.0.2.20', 'ports' => [443] }] }))
    command = described_class.command(context, ['puppet'])
    expect(command).to include('HTTP_PROXY=http://proxy.empeira.internal:3128',
                               'https_proxy=http://proxy.empeira.internal:3128')
    expect(command.find { |entry| entry.start_with?('NO_PROXY=') })
      .to include('.empeira.internal', 'direct.example', '192.0.2.20')
    record = {}
    execute = ->(arguments) { runtime_proxy_result(arguments, 'direct-node') }
    proxy = described_class.new(context: context, record: record, execute: execute, persist: -> {})
    expect(proxy.reconcile).to be(true)
    expect(record.dig('runtime_proxy', 'current', 'direct')).to include('direct.example', '192.0.2.20')
    expect(described_class.valid_inventory?(record.fetch('runtime_proxy'))).to be(true)
  end
end

RSpec.describe Empeira::RuntimeProxyGuest do
  let(:root) { Pathname(@directory).join('guest') }
  let(:apt) { root.join('etc/apt/apt.conf.d/90-empeira-proxy') }
  let(:dnf) { root.join('etc/dnf/dnf.conf') }
  let(:definition) do
    { 'url' => 'http://proxy.empeira.internal:3128', 'direct' => ['direct.example'],
      'no_proxy' => 'localhost,.empeira.internal,direct.example' }
  end

  before do
    apt.parent.mkpath
    dnf.parent.mkpath
    dnf.write("[main]\ngpgcheck=1\nsslverify=1\n[local]\nproxy=\nbaseurl=https://direct.example/repo\n")
  end

  def reconcile(desired = definition, accepted = [definition])
    described_class.new({ 'desired' => desired, 'accepted' => accepted }, root: root).reconcile
  end

  it 'creates persistent credential-free APT and DNF settings, preserving sources and repository overrides' do
    sources = root.join('etc/apt/sources.list')
    sources.write('deb https://packages.example stable main')
    expect(reconcile).to be(true)
    expect(apt.read).to include('Acquire::http::Proxy', 'Acquire::https::Proxy')
    expect(apt.read).to include('Acquire::http::Proxy::direct.example "DIRECT";')
    expect(dnf.read).to include('gpgcheck=1', 'sslverify=1', "[local]\nproxy=\n")
    expect(sources.read).to eq('deb https://packages.example stable main')
    expect(reconcile).to be(false)
    expect(reconcile(nil)).to be(true)
    expect(apt).not_to exist
    expect(dnf.read).not_to include('EMPEIRA', 'proxy.empeira.internal')
    expect(root.join('etc/profile.d/90-empeira-proxy.sh').read).to include("export http_proxy=''\n")
    expect(reconcile(nil)).to be(false)
  end

  it 'respects flat and nested foreign host-specific APT proxy and DIRECT directives' do
    foreign = apt.parent.join('95-puppet-proxy')
    content = "Acquire::http::Proxy::direct.example \"DIRECT\";\n" \
              "Acquire { https { Proxy { custom.example \"http://custom.example:3128\"; }; }; };\n"
    foreign.write(content)
    expect(reconcile).to be(true)
    expect(foreign.read).to eq(content)
  end

  it 'accepts native hash comments in nested APT list configuration' do
    apt.parent.join('01autoremove').write("APT { NeverAutoRemove {\n # comment\n \"synthetic-kernel.*\"; }; };\n")
    expect(reconcile).to be(true)
    expect(reconcile).to be(false)
  end

  it 'rejects conflicting foreign global APT settings without replacing them' do
    foreign = apt.parent.join('99-puppet-proxy')
    foreign.write('Acquire { http { Proxy "DIRECT"; }; };')
    expect { reconcile }.to raise_error(/Foreign APT.*conflicts/)
    expect(apt).not_to exist
    expect(foreign.read).to include('DIRECT')
  end

  it 'rejects conflicting DNF main settings while leaving repository settings alone' do
    dnf.write("[main]\nproxy=http://custom.example:3128\n")
    expect { reconcile }.to raise_error(/Foreign DNF.*conflicts/)
    expect(dnf.read).to eq("[main]\nproxy=http://custom.example:3128\n")
  end

  it 'preserves later foreign changes outside its DNF block and removes only its owned block' do
    reconcile
    dnf.write("#{dnf.read}[puppet]\nbaseurl=https://packages.example/new\nproxy=\n")
    expect(reconcile).to be(false)
    reconcile(nil)
    expect(dnf.read).to include('[puppet]', 'baseurl=https://packages.example/new')
  end

  it 'refuses to overwrite or delete a modified owned APT file' do
    reconcile
    apt.write("#{apt.read}// changed by another owner")
    expect { reconcile }.to raise_error(/Foreign or modified/)
    expect { reconcile(nil) }.to raise_error(/Foreign or modified/)
  end

  it 'rejects symlinked proxy targets without writing through them' do
    foreign = root.join('foreign')
    foreign.write('preserve')
    File.symlink(foreign, apt)
    expect { reconcile }.to raise_error(/Unsafe or unowned/)
    expect(foreign.read).to eq('preserve')
  end
end
