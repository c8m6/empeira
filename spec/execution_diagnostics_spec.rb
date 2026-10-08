# frozen_string_literal: true

RSpec.describe Empeira::Execution::Diagnostics do
  it 'keeps actionable SSH, DNS, ref and HTTP errors without credentials or private paths' do
    text = <<~OUTPUT
      Permission denied (publickey).
      fatal: Could not resolve host: git.example.org
      error: ref missing does not exist
      the server responded with status 404
      fatal: unable to access 'https://user:password@host/repo?token=hidden'
      Error: token=synthetic-token password="synthetic password"
      Error: Bearer synthetic-bearer
      Error: AWS_SECRET_ACCESS_KEY=synthetic-cloud-key
      Error: {"token": "synthetic-json-token"}
      Error: ghp_syntheticsecret
      Proxy-Authorization: Basic synthetic-proxy
      Load key "/private/path/identity": Permission denied
      Load key "relative/synthetic-identity": Permission denied
      Error: /home/synthetic/.ssh/private-key: Permission denied
      -----BEGIN OPENSSH PRIVATE KEY-----
      fatal: synthetic-private-key
      -----END OPENSSH PRIVATE KEY-----
      Command: git clone ssh://private-alias/repository
    OUTPUT
    result = described_class.clean(text)
    expect(result).to include('Permission denied (publickey)', 'Could not resolve host: git.example.org',
                              'ref missing does not exist', 'status 404', '[REDACTED URL]')
    expect(result).not_to include('synthetic', 'user:password', 'token=hidden', 'Proxy-Authorization',
                                  '/private/path', 'git clone', 'PRIVATE KEY')
  end

  it 'discards unrelated output and removes terminal controls' do
    expect(described_class.clean("Receiving objects...\n\e[31mfatal: connection refused\e[0m\n"))
      .to eq('fatal: connection refused')
  end
end
