# frozen_string_literal: true

require_relative '../support/core_dns_fixture'

RSpec.describe 'Real CoreDNS exact service rewrites', :integration do
  include CoreDNSFixture

  before do
    skip 'Set EMPEIRA_INTEGRATION=1 for real CoreDNS tests' unless ENV['EMPEIRA_INTEGRATION'] == '1'

    prepare_dns_fixture
    @rules = %w[ipam.example.net inventory.example.net].map do |name|
      { 'from' => name, 'to' => 'api-layer.empeira.internal' }
    end
    @files = rewrite_files(@rules)
    @files.write('hosts', "192.0.2.40 api-layer api-layer.empeira.internal\n192.0.2.41 other-api.empeira.internal\n")
    @managed_dns, @managed_id = start_dns_fixture('managed', File.read(@files.path('Corefile')),
                                                  File.read(@files.path('hosts')))
    start_dns_client
    wait_for_dns { dns_query('ipam.example.net').stdout.include?('192.0.2.40') }
  end

  after { cleanup_dns_fixture }

  it 'answers A, AAAA and CNAME locally, preserves exact matching and follows dynamic service addresses' do
    %w[ipam.example.net IPAM.EXAMPLE.NET. inventory.example.net].each do |name|
      result = dns_query(name)
      expect(result).to be_success
      expect(result.stdout).to include('192.0.2.40')
      expect(result.stdout).not_to include('198.51.100.10', 'api-layer.empeira.internal')
    end
    %w[AAAA CNAME].each do |type|
      result = dns_query('ipam.example.net', type)
      expect(result).to be_success
      expect(result.stdout).not_to include('198.51.100.', 'canonical name', 'SERVFAIL', 'NXDOMAIN')
      expect(result.stdout).not_to include('192.0.2.40')
    end
    %w[external.example.net child.ipam.example.net].each do |name|
      expect(dns_query(name).stdout).to include('198.51.100.10')
    end
    expect(dns_query('api-layer.empeira.internal').stdout).to include('192.0.2.40')
    expect(dns_query('unknown.empeira.internal').stdout).not_to include('198.51.100.11')

    @files.write('hosts', "192.0.2.42 api-layer api-layer.empeira.internal\n")
    publish_dns_files(@files)
    wait_for_dns { dns_query('ipam.example.net').stdout.include?('192.0.2.42') }
    expect(dns_command('inspect', '--format', '{{.Id}} {{.State.Running}}', @managed_id))
      .to eq("#{@managed_id} true")
  end

  it 'reloads changed and removed rewrites while the DNS server and its client keep running' do
    changed = @rules.map { |entry| entry.merge('to' => 'other-api.empeira.internal') }
    files = rewrite_files(changed)
    publish_dns_files(files)
    dns_command('kill', '--signal', 'USR1', @managed_id)
    wait_for_dns { dns_query('ipam.example.net').stdout.include?('192.0.2.41') }

    files = rewrite_files([])
    publish_dns_files(files)
    dns_command('kill', '--signal', 'USR1', @managed_id)
    wait_for_dns { dns_query('ipam.example.net').stdout.include?('198.51.100.10') }
    [@managed_id, @dns_client].each do |id|
      expect(dns_command('inspect', '--format', '{{.Id}} {{.State.Running}} {{.RestartCount}}', id))
        .to eq("#{id} true 0")
    end
  end

  it 'never forwards configured names or missing targets to an external resolver' do
    @files = rewrite_files(@rules, additional_resolver: @dns_upstream,
                                   routes: { 'ipam.example.net' => [@dns_upstream] })
    @files.write('hosts', '')
    publish_dns_files(@files)
    dns_command('kill', '--signal', 'USR1', @managed_id)
    wait_for_dns { !dns_query('ipam.example.net').stdout.include?('192.0.2.40') }
    %w[A CNAME PTR MX TXT].each do |type|
      result = dns_query('ipam.example.net', type)
      expect(result.stdout).not_to include('198.51.100.10', '198.51.100.11')
      expect(result.stdout + result.stderr).to include('SERVFAIL')
    end
    expect(dns_query('ipam.example.net', 'AAAA')).to be_success
    # Prove upstream logging works, then inspect every forwarded request.
    expect(dns_query('external.example.net').stdout).to include('198.51.100.10')
    log = dns_command('logs', @dns_containers.first)
    expect(log).to include('external.example.net.')
    forwarded = log.scan(/"\S+ IN (\S+) /).flatten
    expect(forwarded).not_to include('ipam.example.net.', 'inventory.example.net.', 'api-layer.empeira.internal.')
  end
end
