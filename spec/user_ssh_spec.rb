# frozen_string_literal: true

RSpec.describe Empeira::Node::UserSSH do
  let(:app) { Empeira::Application.new(project_path: @directory) }
  let(:runner) { instance_double(Empeira::Execution::Runner) }
  let(:credentials) do
    Empeira::Node::SSHCredentials.new(context: app.context, runner: runner, provider: 'container', hostname: 'node')
  end
  let(:record) { { 'hostname' => 'node.example', 'ssh_host' => '127.0.0.1', 'ssh_port' => 32_001 } }
  let(:client) { described_class.new(runner: runner, credentials: credentials) }

  before do
    allow(app.context.locations).to receive(:workspace).and_return(Pathname(@directory).join('state'))
  end

  [{}, { user: 'deploy' }, { identity: '/some/key' }, { user: 'deploy', identity: '/some/key' }].each do |overrides|
    it "preserves standard SSH authentication with independent overrides #{overrides.keys}" do
      failure = Empeira::Execution::Result.new(stdout: '', stderr: '', exit_status: 255, timed_out: false)
      expect(runner).not_to receive(:run)
      expect(runner).to receive(:stream) do |command, arguments:|
        expect(command).to eq('ssh')
        expect(arguments).to include('-tt', '-l', overrides.fetch(:user, Etc.getpwuid(Process.uid).name),
                                     'node.example', 'HostName=127.0.0.1', 'ProxyJump=none', 'ControlPath=none')
        expect(arguments).not_to include('-F', 'BatchMode=yes', 'IdentitiesOnly=yes', 'PasswordAuthentication=no')
        if overrides[:identity]
          expect(arguments).to include('-i', '/some/key')
        else
          expect(arguments).not_to include('-i')
        end
        expect(arguments.grep(/UserKnownHostsFile/).first).to include(credentials.directory.to_s)
        failure
      end
      expect(client.session(record, **overrides).exit_status).to eq(255)
      expect(credentials.key_path).not_to exist
    end
  end
end
