# frozen_string_literal: true

require_relative 'support/agent_login_terminal'

RSpec.describe 'Native repository login and subsequent host package download' do
  { 'APT' => ['ubuntu', '24.04'], 'DNF' => %w[rocky 9] }.each do |manager, (os, release)|
    context manager do
      let(:target) { Empeira::Agent::Target.new(os: os, release: release, architecture: 'amd64') }
      let(:klass) { manager == 'APT' ? Empeira::Node::AgentRepository : Empeira::Node::DnfAgentRepository }
      let(:source) do
        values = { 'url' => "https://PACKAGES.EXAMPLE.ORG/#{manager.downcase}" }
        manager == 'APT' ? values.merge('suite' => 'noble', 'component' => 'main') : values
      end
      let(:files) { {} }
      let(:calls) { [] }
      let(:input) { AgentLoginTerminal.new("yes\nfixture-user\nfixture-password\n") }
      let(:output) { AgentLoginTerminal.new }
      let(:authentication) { Empeira::Agent::Authentication.new(url: source['url'], input: input, output: output) }
      let(:download) { Empeira::Agent::Download.new(authentication: authentication) }
      let(:success) { Empeira::Execution::Result.new(stdout: '', stderr: '', exit_status: 0, timed_out: false) }
      let(:copy) { ->(path, destination, _) { files[destination] = File.read(path) } }
      let(:metadata_attempts) { [] }
      let(:execute) do
        lambda do |arguments|
          calls << arguments
          network = arguments.first == 'dnf' || arguments.include?('update')
          metadata_attempts << arguments if network
          if network && files.values.none? { |text| text.include?('fixture-password') }
            success.with(exit_status: 1, stderr: 'Status code: 401 for https://packages.example.org/metadata')
          else
            success.with(stdout: native_output(arguments))
          end
        end
      end
      let(:resolver) do
        klass.new(source: source, package: 'synthetic-agent', version: '1.2.3', target: target,
                  execute: execute, copy: copy, download: download, authentication: authentication,
                  directory: @directory)
      end

      def native_output(arguments)
        if arguments.first == 'apt-cache'
          "Package: synthetic-agent\nVersion: 1.2.3-1\nArchitecture: amd64\nFilename: agent.deb\nSHA256: #{'a' * 64}\n"
        elsif arguments.include?('--print-uris')
          "'https://packages.example.org/agent.deb' agent.deb 100\n"
        elsif arguments.include?('--location')
          "Last metadata expiration check: synthetic fixture\nhttps://packages.example.org/agent.rpm\n"
        elsif arguments.first == 'dnf'
          'synthetic-agent|0|1.2.3|1|x86_64|empeira-agent'
        else
          ''
        end
      end

      it 'retries failed metadata once, installs temporary credentials and shares the login with the package request' do
        selected = resolver.resolve
        expect(calls.flatten).not_to include('--quiet') if manager == 'DNF'
        expect(output.string.scan('Username:').size).to eq(1)
        expect(metadata_attempts.count { |args| args == metadata_attempts.first }).to eq(2)
        expect(files.values.join).to include('fixture-user', 'fixture-password')
        expect(calls.flatten.join(' ')).not_to include('fixture-user', 'fixture-password')
        http = double('HTTP connection')
        response = double('HTTP response', code: '200', :[] => nil, read_body: nil)
        allow(response).to receive(:read_body).and_yield('synthetic package')
        allow(Net::HTTP).to receive(:start).and_yield(http)
        expect(http).to receive(:request) do |request, &block|
          expect(request['Authorization']).to eq("Basic #{Base64.strict_encode64('fixture-user:fixture-password')}")
          block.call(response)
        end
        download.fetch(selected.fetch('url'), Pathname(@directory).join("package.#{target.format}"))
      end

      %w[403 407].each do |code|
        it "retains native HTTP #{code} diagnostics without triggering repository login" do
          allow(execute).to receive(:call) do |arguments|
            calls << arguments
            if %w[apt-get dnf].include?(arguments.first)
              success.with(exit_status: 1, stderr: "Status code: #{code} for https://packages.example.org/metadata")
            else
              success
            end
          end
          expect { resolver.resolve }.to raise_error(Empeira::Error) do |error|
            expect(error.message).to include("Status code: #{code}", 'https://packages.example.org/metadata',
                                             'Response: Not provided separately')
          end
          expect(output.string).to be_empty
        end
      end
    end
  end
end
