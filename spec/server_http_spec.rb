# frozen_string_literal: true

RSpec.describe Empeira::Server::HTTP do
  def result(stdout, stderr: '', status: 22)
    Empeira::Execution::Result.new(stdout: stdout, stderr: stderr, exit_status: status, timed_out: false)
  end

  it 'uses the last actual HTTP header block after a CONNECT or interim response' do
    data = result("HTTP/1.1 200 Connection established\r\n\r\nHTTP/1.1 503 Custom unavailable\r\n" \
                  "Content-Type: text/plain\r\nCookie: fixture-cookie\r\n\r\nMaintenance in progress")
    expect(described_class.response(data)).to include(status: '503', reason: 'Custom unavailable',
                                                      body: 'Maintenance in progress')
    diagnostic = described_class.failure(data, url: 'https://server.empeira.internal/status', operation: 'Check server')
    expect(diagnostic).to include('503 Custom unavailable', 'Maintenance in progress')
    expect(diagnostic).not_to include('fixture-cookie', 'Connection established')
  end

  it 'preserves reason phrases without inventing one for HTTP/2' do
    data = result("HTTP/2 404\r\ncontent-type: application/json\r\n\r\n{\"error\":\"missing\"}")
    expect(described_class.response(data)).to include(status: '404', reason: nil, body: '{"error":"missing"}')
  end

  it 'does not treat numbers in arbitrary native output as HTTP response headers' do
    data = result('curl failed: status 401', stderr: 'curl: Could not resolve host')
    diagnostic = described_class.failure(data, url: 'https://server.example.org/status', operation: 'Check server')
    expect(diagnostic).to include('HTTP status / reason: Not reported separately', 'Could not resolve host',
                                  'status 401')
    expect(diagnostic).not_to include('HTTP status: 401')
  end
end
