# frozen_string_literal: true

require_relative 'support/http_fixture'
require_relative 'support/agent_login_terminal'

RSpec.describe 'Agent HTTPS acquisition and interactive authentication' do
  let(:input) { AgentLoginTerminal.new("yes\nfixture-user\nfixture-password\n") }
  let(:output) { AgentLoginTerminal.new }
  let(:path) { Pathname(@directory).join('package.deb') }
  let(:authorization) { "Basic #{Base64.strict_encode64('fixture-user:fixture-password')}" }

  def server(&)
    @server = HTTPFixture.new(&)
    store = OpenSSL::X509::Store.new
    store.add_cert(@server.certificate)
    allow(Net::HTTP).to receive(:start).and_wrap_original do |method, *arguments, **options, &block|
      method.call(*arguments, **options, cert_store: store, &block)
    end
    @server
  end

  def download(origin = @server.url('/apt'))
    authentication = Empeira::Agent::Authentication.new(url: origin, input: input, output: output)
    [Empeira::Agent::Download.new(authentication: authentication), authentication]
  end

  after { @server&.close }

  it 'retries one real 401 with interactive credentials and reuses them on a subsequent same-origin package request' do
    server do |_, headers|
      if headers['authorization'] == authorization
        ['200', 'OK', 'synthetic package']
      else
        ['401', 'Login required', 'Authentication required']
      end
    end
    transport, authentication = download
    transport.fetch(@server.url('/apt/metadata'), path, operation: 'Retrieve agent metadata')
    transport.fetch(@server.url('/apt/pool/package.deb'), path)
    expect(path.read).to eq('synthetic package')
    expect(@server.requests.map { |_, headers| headers['authorization'] }).to eq([nil, authorization, authorization])
    expect(authentication.credentials(@server.url)).to eq(%w[fixture-user fixture-password])
    expect(output.string.scan('Username:').size).to eq(1)
  end

  it 'diagnoses a second 401 as an interactive rejection and preserves the actual last server response' do
    server { |_, headers| ['401', 'Rejected login', "Denied #{headers['authorization']} fixture-password"] }
    transport, = download
    expect { transport.fetch(@server.url('/package.deb'), path) }.to raise_error(Empeira::Error) do |error|
      expect(error.message).to include('interactive login was rejected', '401 Rejected login',
                                       @server.url('/package.deb'))
      expect(error.full_message).not_to include('ENV credentials', 'explicit credentials', 'fixture-password',
                                                authorization)
    end
    expect(@server.requests.size).to eq(2)
    expect(path).not_to exist
  end

  it 'uses ENV credentials on the first request and never offers replacement login' do
    ENV['EMPEIRA_AGENT_REPO_USERNAME'] = 'fixture-user'
    ENV['EMPEIRA_AGENT_REPO_PASSWORD'] = 'fixture-password'
    server { ['401', 'Unauthorized', 'ENV login rejected'] }
    transport, = download
    expect { transport.fetch(@server.url('/package.deb'), path) }
      .to raise_error(Empeira::Error, /ENV credentials were not replaced/)
    expect(@server.requests.size).to eq(1)
    expect(@server.requests.first.last['authorization']).to eq(authorization)
    expect(output.string).to be_empty
  end

  it 'keeps foreign origins unauthenticated without prompting for the configured origin' do
    server { ['401', 'Unauthorized', 'Foreign repository requires authentication'] }
    transport, = download('https://other.example.org/apt')
    expect { transport.fetch(@server.url('/package.deb'), path) }
      .to raise_error(Empeira::Error, /different origin.*source credentials were not forwarded/)
    expect(@server.requests.size).to eq(1)
    expect(@server.requests.first.last['authorization']).to be_nil
    expect(output.string).to be_empty
  end

  it 'retains the original HTTP diagnosis when the interactive login is cancelled' do
    input.string = "no\n"
    server { ['401', 'Unauthorized', 'Authentication required'] }
    transport, = download
    expect { transport.fetch(@server.url('/package.deb'), path) }.to raise_error(Empeira::Error) do |error|
      expect(error.message).to include('login cancelled', '401 Unauthorized', 'Authentication required')
    end
    expect(@server.requests.size).to eq(1)
  end

  it 'reports the failed request and ENV guidance without reading input when there is no TTY' do
    allow(input).to receive(:tty?).and_return(false)
    expect(input).not_to receive(:gets)
    server { ['401', 'Unauthorized', 'Authentication required'] }
    transport, = download
    expect { transport.fetch(@server.url('/package.deb'), path) }.to raise_error(Empeira::Error) do |error|
      expect(error.message).to include('noninteractive environments', 'EMPEIRA_AGENT_REPO_USERNAME',
                                       @server.url('/package.deb'), '401 Unauthorized')
    end
    expect(@server.requests.size).to eq(1)
  end

  it 'applies the same HTTP diagnosis to real VM image and checksum requests' do
    server { ['502', 'Upstream unavailable', 'Image service failed'] }
    url = @server.url('/base.qcow2')
    image = Empeira::VM::ImageSource::Image.new(
      identity: Empeira::Images::Identity.new(distribution: 'ubuntu', version: '24.04', architecture: 'amd64',
                                              source: url, revision: 'a' * 64, checksum: 'a' * 64),
      url: url, filename: 'base.qcow2'
    )
    locations = Empeira::Platform::Locations.new(home: @directory, environment: {})
    expect { Empeira::VM::ImageCache.new(locations: locations).fetch(image) }.to raise_error(Empeira::Error) do |error|
      expect(error.message).to include('Download VM base image', url, '502 Upstream unavailable',
                                       'Image service failed')
    end
    expect { Empeira::VM::ImageSource.new.send(:read_text, @server.url('/SHA256SUMS')) }
      .to raise_error(Empeira::Error) do |error|
        expect(error.message).to include('Retrieve VM image checksum', '/SHA256SUMS', '502 Upstream unavailable')
      end
  end

  %w[400 403 404 407 429 500 502 503].each do |code|
    it "reports a real HTTP #{code}, response body and URL without prompting" do
      server { [code, 'Synthetic status reason', "First explanation\nSecond explanation"] }
      transport, = download
      expect { transport.fetch(@server.url('/package.deb'), path) }.to raise_error(Empeira::Error) do |error|
        expect(error.message).to include("#{code} Synthetic status reason", @server.url('/package.deb'),
                                         "  First explanation\n  Second explanation")
      end
      expect(output.string).to be_empty
      expect(path).not_to exist
      expect(@server.requests.size).to eq(1)
    end
  end
end
