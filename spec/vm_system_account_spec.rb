# frozen_string_literal: true

require 'shellwords'
RSpec.describe 'Dedicated system account guard' do
  let(:runner) { Empeira::Execution::Runner.new }
  let(:root) { Pathname(@directory).join('guest') }
  let(:home) { root.join('var/lib/empeira') }
  let(:bin) { root.join('bin') }
  let(:uid) { 123 }
  let(:gid) { 456 }
  let(:observed_uid) { uid }
  let(:account) { "empeira:x:#{uid}:#{gid}::#{home}:/bin/bash" }
  let(:password) { '!*synthetic-locked' }

  before do
    home.mkpath
    home.chmod(0o700)
    bin.mkpath
    root.join('login.defs').write("UID_MIN #{uid + 1000}\nGID_MIN #{gid + 1000}\n")
  end

  # rubocop:disable-next Metrics/AbcSize -- Execute the unchanged guest guard with isolated account and metadata tools.
  def verify
    prepare_metadata_tool
    bin.join('getent').write(<<~SCRIPT)
      #!/bin/sh
      test "$2" = empeira || exit 2
      case "$1" in
        passwd) test -n #{Shellwords.escape(account)} || exit 2; printf '%s\n' #{Shellwords.escape(account)} ;;
        shadow) printf '%s\n' #{Shellwords.escape("empeira:#{password}:0:0:99999:7:::")} ;;
        *) exit 2 ;;
      esac
    SCRIPT
    bin.join('getent').chmod(0o700)
    source = Pathname(__dir__).join('../resources/nodes/management/system_account.sh').read
    source = source.gsub('/etc/login.defs', root.join('login.defs').to_s).gsub('/var/lib/empeira', home.to_s)
    script = "set -eu\nfail() { echo \"Management account: $1\" >&2; exit 1; }\n#{source}\nverify_account verified"
    runner.run('sh', arguments: ['-c', script], environment: { 'PATH' => "#{bin}:#{ENV.fetch('PATH')}" })
  end

  def prepare_metadata_tool
    bin.join('stat').write(<<~SCRIPT)
      #!#{RbConfig.ruby}
      metadata = File.lstat(ARGV.last)
      puts [#{observed_uid}, #{gid}, (metadata.mode & 0o777).to_s(8)].join(':')
    SCRIPT
    bin.join('stat').chmod(0o700)
  end

  it 'accepts an allocated system UID/GID, locked password and private owned home' do
    expect(verify).to be_success
  end
  it 'rejects a regular UID without exposing account credentials' do
    root.join('login.defs').write("UID_MIN #{uid}\nGID_MIN #{gid + 1000}\n")
    result = verify
    expect(result).not_to be_success
    expect(result.stderr).to include('dedicated system UID')
    expect(result.stderr).not_to include(password)
  end
  it 'rejects an unlocked password without printing the shadow value' do
    allow(self).to receive(:password).and_return('synthetic-secret-hash')
    result = verify
    expect(result).not_to be_success
    expect(result.stderr).to include('password must stay locked')
    expect(result.stderr).not_to include(password)
  end
  it 'rejects changed home ownership without repairing it' do
    allow(self).to receive(:observed_uid).and_return(uid + 1)
    result = verify
    expect(result).not_to be_success
    expect(result.stderr).to include('home ownership or permissions changed')
  end
  it 'rejects changed home metadata and permissions without repairing them' do
    home.chmod(0o755)
    result = verify
    expect(result).not_to be_success
    expect(result.stderr).to include('home ownership or permissions changed')
    expect(home.stat.mode & 0o777).to eq(0o755)
  end
  it 'rejects a removed account' do
    allow(self).to receive(:account).and_return('')
    result = verify
    expect(result).not_to be_success
    expect(result.stderr).to include('missing system SSH account empeira')
  end
  it 'rejects a home symlink without modifying its target' do
    FileUtils.remove_dir(home)
    target = root.join('another-home')
    target.mkpath
    File.symlink(target, home)
    result = verify
    expect(result).not_to be_success
    expect(result.stderr).to include('home is a symlink')
    expect(target).to exist
  end
  it 'rejects missing or ambiguous system UID bounds' do
    root.join('login.defs').write("UID_MIN 1000\nUID_MIN 2000\nGID_MIN 3000\n")
    result = verify
    expect(result).not_to be_success
    expect(result.stderr).to include('unverifiable system SSH UID/GID range')
  end
end
