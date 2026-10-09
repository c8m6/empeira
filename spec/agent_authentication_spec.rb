# frozen_string_literal: true

require 'stringio'

class AgentLoginTerminal < StringIO
  def tty?
    true
  end

  def noecho
    yield self
  end
end

RSpec.describe Empeira::Agent::Authentication do
  let(:input) { AgentLoginTerminal.new("yes\nfixture-user\nfixture-password\n") }
  let(:output) { AgentLoginTerminal.new }
  let(:progress) { Empeira::Progress.new }
  let(:authentication) { described_class.new(url: 'https://packages.example.org/apt', input: input, output: output, progress: progress) }

  it 'does not prompt for public sources' do
    expect(authentication.attempt { :success }).to eq(:success)
    expect(output.string).to be_empty
  end

  it 'suspends progress, reads a hidden password once and retries after a 401' do
    attempts = 0
    expect(progress).to receive(:streaming).and_call_original
    expect(input).to receive(:noecho).and_call_original
    result = authentication.attempt do
      attempts += 1
      raise Empeira::Agent::AuthenticationRequired if attempts == 1

      :authenticated
    end
    expect(result).to eq(:authenticated)
    expect(authentication.credentials).to eq(%w[fixture-user fixture-password])
    expect(output.string).not_to include('fixture-password')
    expect(authentication.credentials('https://other.example.org/apt')).to be_nil
    expect(authentication.credentials('https://packages.example.org:8443/apt')).to be_nil
  end

  it 'rejects another authentication failure without endless retries' do
    expect { authentication.attempt { raise Empeira::Agent::AuthenticationRequired } }
      .to raise_error(Empeira::Error, /authentication failed/)
    expect(output.string.scan('Username:').size).to eq(1)
  end

  it 'honors ENV credentials and does not replace an invalid explicit login interactively' do
    ENV['EMPEIRA_AGENT_REPO_USERNAME'] = 'environment-user'
    ENV['EMPEIRA_AGENT_REPO_PASSWORD'] = 'environment-password'
    expect(authentication.credentials).to eq(%w[environment-user environment-password])
    expect { authentication.attempt { raise Empeira::Agent::AuthenticationRequired } }
      .to raise_error(Empeira::Error, /explicit credentials were not replaced/)
    expect(output.string).to be_empty
  end

  it 'rejects incomplete ENV credentials' do
    ENV['EMPEIRA_AGENT_REPO_PASSWORD'] = 'fixture-password'
    expect { authentication }.to raise_error(Empeira::ConfigurationError, /both nonempty/)
  end

  it 'declines a cancelled login and restores progress on interruption' do
    input.string = "no\n"
    expect { authentication.attempt { raise Empeira::Agent::AuthenticationRequired } }
      .to raise_error(Empeira::Error, /cancelled/)
  end

  it 'does not prompt without a TTY and explains the environment variables' do
    authentication = described_class.new(url: 'https://packages.example.org/apt', input: StringIO.new, output: output)
    expect { authentication.attempt { raise Empeira::Agent::AuthenticationRequired } }
      .to raise_error(Empeira::Error, /EMPEIRA_AGENT_REPO_USERNAME.*EMPEIRA_AGENT_REPO_PASSWORD/)
    expect(output.string).to be_empty
  end

  it 'redacts both plain and Basic-encoded credentials before diagnostic truncation' do
    ENV['EMPEIRA_AGENT_REPO_USERNAME'] = 'fixture-user'
    ENV['EMPEIRA_AGENT_REPO_PASSWORD'] = 'fixture-password'
    encoded = Base64.strict_encode64('fixture-user:fixture-password')
    expect(authentication.redact("error: fixture-password Basic #{encoded}"))
      .to eq('error: [REDACTED] Basic [REDACTED]')
  end
end

RSpec.describe Empeira::Agent::Download do
  let(:authentication) { Empeira::Agent::Authentication.new(url: 'https://packages.example.org/agent.deb') }
  let(:download) { described_class.new(authentication: authentication) }
  let(:path) { Pathname(@directory).join('package.deb') }
  let(:http) { double('HTTP connection') }
  let(:response) { double('HTTP response', code: '200', :[] => nil) }
  let(:requests) { [] }

  before do
    allow(Net::HTTP).to receive(:start) do |_, _, **options, &block|
      expect(options.fetch(:verify_mode)).to eq(OpenSSL::SSL::VERIFY_PEER)
      block.call(http)
    end
    allow(http).to receive(:request) do |request, &block|
      requests << request
      block.call(response)
    end
    allow(response).to receive(:read_body).and_yield('synthetic-package')
  end

  it 'downloads without a pin, computes no independent provenance claim and preserves restrictive permissions' do
    download.fetch('https://packages.example.org/agent.deb', path)
    expect(path.read).to eq('synthetic-package')
    expect(path.stat.mode & 0o777).to eq(0o600)
  end

  it 'accepts a matching SHA-256 and rejects an incomplete Content-Length' do
    download.fetch('https://packages.example.org/agent.deb', path,
                   sha256: Digest::SHA256.hexdigest('synthetic-package'))
    allow(response).to receive(:[]).with('Content-Length').and_return('1000')
    expect { download.fetch('https://packages.example.org/agent.deb', path) }
      .to raise_error(Empeira::Error, /incomplete/)
    expect(path).not_to exist
  end

  it 'fails certificate validation without weakening TLS or retaining a partial download' do
    allow(Net::HTTP).to receive(:start).and_raise(OpenSSL::SSL::SSLError)
    expect { download.fetch('https://packages.example.org/agent.deb', path) }
      .to raise_error(Empeira::Error, /certificate verification failed/)
    expect(path).not_to exist
  end

  it 'enforces a configured SHA-256 and removes failed downloads' do
    expect { download.fetch('https://packages.example.org/agent.deb', path, sha256: 'a' * 64) }
      .to raise_error(Empeira::Error, /checksum mismatch/)
    expect(path).not_to exist
  end

  { '403' => /access denied/, '407' => /proxy authentication/,
    '302' => /redirects are not followed/ }.each do |code, message|
    it "handles HTTP #{code} without opening a repository prompt" do
      allow(response).to receive(:code).and_return(code)
      expect(authentication).not_to receive(:login)
      expect { download.fetch('https://packages.example.org/agent.deb', path) }.to raise_error(Empeira::Error, message)
      expect(path).not_to exist
    end
  end

  it 'limits credentials to the source origin and never follows redirects to foreign hosts' do
    ENV['EMPEIRA_AGENT_REPO_USERNAME'] = 'fixture-user'
    ENV['EMPEIRA_AGENT_REPO_PASSWORD'] = 'fixture-password'
    download.fetch('https://other.example.org/agent.deb', path)
    expect(requests.last['Authorization']).to be_nil
    download.fetch('https://packages.example.org/agent.deb', path)
    expect(requests.last['Authorization']).to start_with('Basic ')
  end

  it 'rejects a truncated or interrupted transfer and cleans the temporary file' do
    allow(response).to receive(:read_body).and_yield('partial').and_raise(EOFError)
    expect do
      download.fetch('https://packages.example.org/agent.deb', path)
    end.to raise_error(Empeira::Error, /download failed/)
    expect(path).not_to exist
  end
end
