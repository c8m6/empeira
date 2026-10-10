# frozen_string_literal: true

require_relative '../resources/nodes/interactive_tools'

RSpec.describe Empeira::InteractiveToolsGuest do
  let(:root) { Pathname(@directory).join('guest') }
  let(:binary) { root.join('opt/puppetlabs/bin') }
  let(:global) { root.join('etc/bash.bashrc') }
  let(:profile) { root.join('etc/profile.d/90-empeira-tools.sh') }

  before do
    binary.mkpath
    %w[puppet facter].each do |name|
      binary.join(name).write("#!/bin/sh\nprintf '#{name}-version\\n'\n")
      binary.join(name).chmod(0o755)
    end
    global.parent.mkpath
    global.write("# Existing global initialization\nexport KEPT_GLOBAL=yes\n")
  end

  def reconcile
    described_class.new({ 'puppet' => '/opt/puppetlabs/bin/puppet' }, root: root).reconcile
  end

  def shell(arguments)
    Empeira::Execution::Runner.new.run('bash', arguments: arguments,
                                               environment: { 'PATH' => '/usr/bin:/bin', 'HOME' => root.to_s })
  end

  it 'uses the installed tool directory and preserves both OS and personal startup configuration' do
    personal = root.join('.bashrc')
    personal.write("export PERSONAL=yes\n")
    original = global.read
    expect(reconcile).to eq('changed' => true, 'directory' => '/opt/puppetlabs/bin')
    expect(global.read).to end_with(original)
    expect(personal.read).to eq("export PERSONAL=yes\n")
    expect(profile.stat.mode & 0o777).to eq(0o644)
    expect(reconcile.fetch('changed')).to be(false)
  end

  it 'exposes puppet and facter in an interactive non-login shell without duplicating PATH entries' do
    reconcile
    result = shell(['--noprofile', '--rcfile', global.to_s, '-ic',
                    ". #{profile}; . #{profile}; command -v puppet; command -v facter; puppet --version; " \
                    "facter --version; printf '%s\\n' \"$PATH\"; printf '%s\\n' \"$KEPT_GLOBAL\""])
    expect(result).to be_success
    expect(result.stdout).to include("#{binary}/puppet\n", "#{binary}/facter\n", 'puppet-version', 'facter-version')
    expect(result.stdout.lines[-2].strip.split(':')).to eq([binary.to_s, '/usr/bin', '/bin'])
    expect(result.stdout.lines.last.strip).to eq('yes')
  end

  it 'supports interactive login initialization and leaves non-interactive PATH untouched' do
    reconcile
    login = shell(['--noprofile', '--norc', '--login', '-ic', ". #{profile}; command -v puppet; command -v facter"])
    expect(login).to be_success
    expect(login.stdout).to include("#{binary}/puppet\n", "#{binary}/facter\n")
    quiet = shell(['--noprofile', '--norc', '-c', ". #{profile}; printf '%s' \"$PATH\""])
    expect(quiet.stdout).to eq('/usr/bin:/bin')
  end

  it 'refuses foreign or modified owned profile files' do
    reconcile
    profile.write("#{profile.read}# foreign change\n")
    expect { reconcile }.to raise_error(/Foreign or modified/)
  end

  it 'restores readable permissions only on the verified owned tool fragment' do
    reconcile
    profile.chmod(0o600)
    expect(reconcile.fetch('changed')).to be(true)
    expect(profile.stat.mode & 0o777).to eq(0o644)
  end

  it 'refuses modified global hook blocks, preserving unrelated configuration' do
    reconcile
    global.write(global.read.sub('. ', '. changed-'))
    before = global.read
    expect { reconcile }.to raise_error(/Modified Empeira global Bash hook/)
    expect(global.read).to eq(before)
  end

  it 'fails clearly if the agent tools are missing' do
    binary.join('facter').unlink
    expect { reconcile }.to raise_error(/Cannot locate installed puppet and facter/)
    expect(profile).not_to exist
  end

  it 'rejects symlinked global startup files without modifying their destination' do
    target = root.join('foreign')
    target.write('preserve')
    global.unlink
    File.symlink(target, global)
    expect { reconcile }.to raise_error(/Unsafe or unowned/)
    expect(target.read).to eq('preserve')
  end
end
