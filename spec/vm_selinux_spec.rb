# frozen_string_literal: true

RSpec.describe 'Private management SELinux setup' do
  let(:root) { Pathname(@directory).join('guest') }
  let(:bin) { root.join('bin') }
  let(:enforcing) { root.join('sys/fs/selinux/enforce') }
  let(:modules) { "100 ssh pp\n" }
  let(:failure) { false }
  let(:inventory_failure) { false }
  let(:log) { root.join('operations') }

  before do
    bin.mkpath
    enforcing.dirname.mkpath
    enforcing.write("1\n")
    awk = ENV.fetch('PATH').split(File::PATH_SEPARATOR).map { |directory| Pathname(directory).join('awk') }
             .find(&:executable?)
    File.symlink(awk, bin.join('awk'))
  end

  # rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength -- Only isolated fake policy tools can execute here.
  def apply_policy
    bin.join('semodule').write(<<~SCRIPT)
      #!#{RbConfig.ruby}
      if ARGV == ['-lfull']
        exit 4 if #{inventory_failure}
        puts #{modules.inspect}
      else
        File.open(#{log.to_s.inspect}, 'a') { |file| file.puts ARGV.join(' ') }
        exit 3 if #{failure}
      end
    SCRIPT
    bin.join('restorecon').write(<<~SCRIPT)
      #!#{RbConfig.ruby}
      File.open(#{log.to_s.inspect}, 'a') { |file| file.puts "restorecon " + ARGV.join(' ') }
    SCRIPT
    %w[semodule restorecon].each { |tool| bin.join(tool).chmod(0o700) }
    source = Pathname(__dir__).join('../resources/nodes/management/selinux.sh').read
    source = source.gsub('/sys/fs/selinux/enforce', enforcing.to_s)
    script = "set -eu\nfail() { echo \"$1\" >&2; exit 78; }\n#{source}"
    Empeira::Execution::Runner.new.run('/bin/sh', arguments: ['-c', script], environment: { 'PATH' => bin.to_s })
  end

  it 'installs only the owned module and relabels only owned files while retaining enforcement' do
    expect(apply_policy).to be_success
    expect(log.read.lines.map(&:strip)).to eq(['-i /etc/empeira/management/empeira_management.cil',
                                               'restorecon -R /etc/empeira/management'])
    expect(enforcing.read).to eq("1\n")
  end

  it 'refuses to replace a preexisting module at any priority' do
    allow(self).to receive(:modules).and_return("100 ssh pp\n200 empeira_management cil\n")
    result = apply_policy
    expect(result).not_to be_success
    expect(result.stderr).to include('refusing to replace foreign policy')
    expect(log).not_to exist
  end

  it 'does not relabel files or relax enforcement after a failed policy compilation' do
    allow(self).to receive(:failure).and_return(true)
    expect(apply_policy).not_to be_success
    expect(log.read).not_to include('restorecon')
    expect(enforcing.read).to eq("1\n")
  end

  it 'refuses mutation when existing policy cannot be inspected' do
    allow(self).to receive(:inventory_failure).and_return(true)
    result = apply_policy
    expect(result).not_to be_success
    expect(result.stderr).to include('cannot verify existing SELinux modules')
    expect(log).not_to exist
  end

  it 'does not call policy tools on guests without active SELinux' do
    enforcing.delete
    expect(apply_policy).to be_success
    expect(log).not_to exist
  end
end
