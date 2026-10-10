# frozen_string_literal: true

require_relative '../support/network_redirect_fixture'

RSpec.describe 'Transparent TCP redirects', :integration do
  include NetworkRedirectFixture

  Empeira::Runtime.registry.names.each do |engine|
    context engine do
      let(:engine) { engine }
      let(:project) { File.join(@directory, 'control') }

      before do
        skip 'Set EMPEIRA_INTEGRATION=direct-egress for real gateway redirect tests' unless
          ENV['EMPEIRA_INTEGRATION'] == 'direct-egress'

        prepare_redirect_project
      rescue Empeira::Runtime::Unavailable, Empeira::Runtime::UnsupportedCapability => e
        raise if ENV.fetch('EMPEIRA_REQUIRED_RUNTIMES', '').split(',').include?(engine)

        skip e.message
      end

      after do
        next unless @app && redirect_state

        @runtime.remove_service(@reservation_definition, expected_id: @reservation.fetch('id')) if @reservation
        @runtime.remove_service(@canary_definition, expected_id: @canary.fetch('id')) if @canary
        @app.infrastructure.destroy
        expect(redirect_state).to be_nil
      end

      it 'preserves TCP/HTTP data from nodes and Puppet server, revokes old flows and never falls back externally' do
        @original_ip = external_canary
        @app.run_node(hostname: 'container-redirect', provider: 'container')
        @app.run_node(hostname: 'vm-redirect', provider: 'vm') if ENV['EMPEIRA_REDIRECT_VM'] == '1'
        before = redirect_state
        @config['network'] = { 'redirects' => [rule(@original_ip), rule('192.0.2.8', target_port: 8082)],
                               'egress' => [{ 'ip' => @original_ip, 'ports' => [8080] }] }
        reconcile_redirects
        granted_server = redirect_state.dig('control_plane', 'services', 'server')
        expect(granted_server).not_to eq(before.dig('control_plane', 'services', 'server'))
        check_redirect(@original_ip)
        check_redirect('192.0.2.8', target_port: 8082)
        check_redirect_denied(@original_ip, 8082)
        hold_connection(@original_ip, expected: 'preserved') { expect(reconcile_redirects.changed).to be(false) }
        recreate_redirect_target
        expect(redirect_state.dig('control_plane', 'services', 'server')).to eq(granted_server)
        check_redirect(@original_ip)
        @config['network']['egress'] = []
        @config['network']['redirects'] = [rule(@original_ip, target_port: 8082), rule('192.0.2.9', source_port: 8083)]
        reconcile_redirects
        revoked_server = redirect_state.dig('control_plane', 'services', 'server')
        expect(revoked_server).not_to eq(granted_server)
        check_redirect(@original_ip, target_port: 8082)
        check_redirect('192.0.2.9', source_port: 8083)
        check_redirect_denied('192.0.2.8')
        hold_connection(@original_ip, expected: 'revoked') do
          @config['network']['redirects'] = []
          reconcile_redirects
        end
        check_redirect_denied(@original_ip)
        expect_canary_untouched
        after = redirect_state
        expect(after.fetch('nodes')).to eq(before.fetch('nodes'))
        expect(after.dig('control_plane', 'services', 'server')).to eq(revoked_server)
        %w[gateway dns].each do |key|
          expect(after.dig('control_plane', 'services', key)).to eq(before.dig('control_plane', 'services', key))
        end
      end
    end
  end
end
