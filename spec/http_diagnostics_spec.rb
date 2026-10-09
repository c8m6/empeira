# frozen_string_literal: true

RSpec.describe Empeira::Execution::Diagnostics do
  let(:url) { 'https://packages.example.org/apt/pool/agent.deb?version=1.2.3' }

  def http(body: 'First line\nSecond line', status: '404', reason: 'Missing artifact', **options)
    described_class.http(operation: 'Download agent package', url: url, status: status,
                         reason: reason, body: body, **options)
  end

  %w[400 401 403 404 407 429 500 502 503].each do |status|
    it "retains the actual HTTP #{status} and custom server reason without guessing a standard phrase" do
      expect(http(status: status)).to include('Download agent package', url,
                                              "HTTP status: #{status} Missing artifact", 'Response:')
    end
  end

  it 'preserves JSON and multiline text responses' do
    expect(http(body: '{"error":"rate limit","retry":42}', content_type: 'application/json'))
      .to include('{"error":"rate limit","retry":42}')
    expect(http(body: "First line\nSecond line")).to include("  First line\n  Second line")
  end

  it 'labels HTML and bounds a large response without discarding the available prefix' do
    result = http(body: "<html>Useful explanation#{'x' * 20_000}</html>", content_type: 'text/html')
    expect(result).to include('[HTML response]', 'Useful explanation', '[Truncated diagnostic')
    expect(result.bytesize).to be < 9000
  end

  it 'distinguishes an empty, unavailable and binary response body' do
    expect(http(body: '')).to include('[Empty response body]')
    expect(http(body: nil)).to include('[No response body available]')
    expect(http(body: "\x89PNG\0secret".b)).to include('[Binary response body omitted]')
    expect(http(body: 'binary-payload', content_type: 'application/octet-stream'))
      .not_to include('binary-payload')
  end

  it 'preserves URL hosts, ports, paths and nonsensitive queries while removing credentials and tokens' do
    value = 'https://fixture-user:fixture-password@packages.example.org:8443/apt/pool/agent.deb?' \
            'version=1.2.3&access_token=fixture-token&X-Amz-Signature=fixture-signature'
    result = described_class.http(operation: 'Download', url: value, status: '401', reason: 'Unauthorized',
                                  body: 'fixture-user fixture-password fixture-token fixture-signature')
    expect(result).to include('packages.example.org:8443/apt/pool/agent.deb?', 'version=1.2.3', '[REDACTED]')
    expect(result).not_to include('fixture-user', 'fixture-password', 'fixture-token', 'fixture-signature')
  end

  it 'redacts known credentials, headers, tokens, keys and terminal controls before truncating' do
    body = <<~BODY
      Helpful explanation
      Authorization: Basic fixture-authorization
      Proxy-Authorization: Basic fixture-proxy
      Cookie: fixture-cookie
      Set-Cookie: fixture-set-cookie
      password="fixture-password" token=fixture-token
      -----BEGIN PRIVATE KEY-----
      fixture-private-key
      -----END PRIVATE KEY-----
      #{Base64.strict_encode64('fixture-user:fixture-password')}
      \e[31mfixture-user\e[0m fixture-password
      #{'x' * 20_000}
    BODY
    result = http(body: body, secrets: %w[fixture-user fixture-password])
    expect(result).to include('Helpful explanation', '[REDACTED]', '[Truncated diagnostic')
    expect(result).not_to include('fixture-', 'PRIVATE KEY', "\e", 'Authorization:', 'Cookie:')
  end

  { SocketError.new('getaddrinfo failure') => 'DNS resolution failed',
    Errno::ECONNREFUSED.new => 'Connection refused', Timeout::Error.new('read timeout') => 'Connection timed out',
    OpenSSL::SSL::SSLError.new('certificate expired') => 'certificate verification failed' }.each do |error, label|
    it "reports #{label} without inventing an HTTP status" do
      result = described_class.transport(operation: 'Download', url: url, error: error)
      expect(result).to include(label, url, 'No HTTP response received')
      expect(result).not_to match(/HTTP status: \d/)
    end
  end

  it 'retains a received HTTP status when a transfer fails after receiving headers' do
    response = Net::HTTPOK.new('1.1', '200', 'Custom success')
    result = described_class.transport(operation: 'Download', url: url, error: EOFError.new('incomplete'),
                                       response: response)
    expect(result).to include('200 Custom success', 'incomplete')
    expect(result).not_to include('No HTTP response received')
  end

  it 'keeps a proxy CONNECT response distinct from a repository authentication failure' do
    response = Net::HTTPProxyAuthenticationRequired.new('1.1', '407', 'Proxy Authentication Required')
    error = Net::HTTPFatalError.new('proxy failed', response)
    result = described_class.transport(operation: 'Download', url: url, error: error)
    expect(result).to include('Proxy connection failed', '407 Proxy Authentication Required')
  end

  it 'retains native URLs and original status details while naming information the tool did not provide' do
    result = Empeira::Execution::Result.new(stdout: "Explanation without an error keyword\n",
                                            stderr: 'Status code: 503 for https://packages.example.org/repodata/repomd.xml',
                                            exit_status: 1, timed_out: false)
    text = described_class.native(result, operation: 'Resolve DNF package', tool: 'dnf')
    expect(text).to include('Status code: 503', 'https://packages.example.org/repodata/repomd.xml',
                            'Explanation without an error keyword', 'Response: Not provided separately by dnf')
    expect(text).not_to include('HTTP status: 503')
  end
end
