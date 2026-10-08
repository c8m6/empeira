# frozen_string_literal: true

module OpenVoxViewFixture
  def openvox_view
    { 'name' => 'openvoxview', 'image' => { 'repository' => 'ghcr.io/voxpupuli/openvoxview', 'tag' => 'v1.8.0' },
      'environment' => { 'LISTEN' => '0.0.0.0', 'PORT' => '5000',
                         'PUPPETDB_HOST' => 'puppetdb.empeira.internal', 'PUPPETDB_PORT' => '8080',
                         'PUPPETDB_TLS' => 'false' } }
  end
end
