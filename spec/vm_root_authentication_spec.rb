# frozen_string_literal: true

require 'shellwords'

RSpec.describe 'Root management account preparation' do
  let(:bin) { Pathname(@directory).join('bin') }
  let(:shadow) { Pathname(@directory).join('root-shadow') }
  let(:changes) { Pathname(@directory).join('account-changes') }
  let(:password) { '!*synthetic-locked' }
  let(:uid) { 0 }
  let(:shell) { '/bin/sh' }

  before do
    bin.mkpath
    shadow.write("root:#{password}:0:0:99999:7:::\n")
    tool('id', 'printf "0\\n"')
    tool('getent', <<~SCRIPT)
      test "$2" = root || exit 2
      case "$1" in
        passwd) printf '%s\n' #{Shellwords.escape("root:x:#{uid}:0::/root:#{shell}")} ;;
        shadow) cat #{Shellwords.escape(shadow.to_s)} ;;
        *) exit 2 ;;
      esac
    SCRIPT
    tool('usermod', <<~SCRIPT)
      test "$1" = --password && test "$2" = '*' && test "$3" = root || exit 2
      printf 'changed\n' >> #{Shellwords.escape(changes.to_s)}
      printf 'root:*:0:0:99999:7:::\n' > #{Shellwords.escape(shadow.to_s)}
    SCRIPT
  end

  def tool(name, content)
    bin.join(name).write("#!/bin/sh\nset -eu\n#{content}\n")
    bin.join(name).chmod(0o700)
  end

  def execute(setup: true)
    root = Pathname(__dir__).join('../resources/nodes/management')
    source = "set -eu\nfail() { echo \"Root policy: $1\" >&2; exit 1; }\n"
    source += root.join('root_setup.sh').read if setup
    source += root.join('root_check.sh').read
    Empeira::Execution::Runner.new.run('sh', arguments: ['-c', source],
                                             environment: { 'PATH' => "#{bin}:#{ENV.fetch('PATH')}" })
  end

  it 'replaces only an initial account lock with an impossible password hash for key login' do
    expect(execute).to be_success
    expect(shadow.read.split(':')[1]).to eq('*')
    expect(changes.read).to eq("changed\n")
    expect(execute).to be_success
    expect(changes.read).to eq("changed\n")
  end

  ['*', '$6$synthetic-console-password-hash'].each do |value|
    it "preserves an existing unusable or console password value #{value}" do
      allow(self).to receive(:password).and_return(value)
      shadow.write("root:#{value}:0:0:99999:7:::\n")
      expect(execute).to be_success
      expect(changes).not_to exist
      expect(shadow.read.split(':')[1]).to eq(value)
    end
  end

  it 'never repairs a subsequently locked root account during health checks' do
    result = execute(setup: false)
    expect(result).not_to be_success
    expect(result.stderr).to include('root account prevents public-key login')
    expect(result.stderr).not_to include(password)
    expect(changes).not_to exist
  end

  it 'rejects an empty root password without allowing password authentication' do
    shadow.write("root::0:0:99999:7:::\n")
    expect(execute.stderr).to include('empty root password is unsafe')
    expect(changes).not_to exist
  end

  context 'with a changed root UID' do
    let(:uid) { 123 }

    it 'rejects the account without exposing shadow contents' do
      result = execute(setup: false)
      expect(result).not_to be_success
      expect(result.stderr).to include('root UID changed')
      expect(result.stderr).not_to include(password)
    end
  end

  context 'with a login-disabled root shell' do
    let(:shell) { '/usr/sbin/nologin' }

    it 'rejects the account without replacing the shell' do
      expect(execute(setup: false).stderr).to include('root shell prevents management login')
    end
  end
end
