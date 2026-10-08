# frozen_string_literal: true

require 'openssl'

# Synthetic PKCS7 material generated outside the control repository for live catalogs.
class EyamlFixture
  def initialize(project:, directory:)
    @project = Pathname(project)
    @directory = Pathname(directory).join('eyaml-fixture')
  end

  # rubocop:disable-next Metrics/AbcSize -- Prepare one synthetic keypair and encrypted control-repository fixture.
  def prepare
    FileUtils.mkdir_p(@directory)
    key, certificate = material
    @directory.join('private.pem').write(key.to_pem)
    @directory.join('public.pem').write(certificate.to_pem)
    ciphertext = OpenSSL::PKCS7.encrypt([certificate], 'synthetic-eyaml-value',
                                        OpenSSL::Cipher.new('aes-256-cbc'), OpenSSL::PKCS7::BINARY)
    FileUtils.mkdir_p(@project.join('data'))
    data = { 'smoke_eyaml' => "ENC[PKCS7,#{[ciphertext.to_der].pack('m0')}]" }
    @project.join('data/common.eyaml').write(YAML.dump(data))
    @project.join('hiera.yaml').write(YAML.dump(hierarchy))
    { 'enabled' => true, 'private_key' => @directory.join('private.pem').to_s,
      'public_key' => @directory.join('public.pem').to_s }
  end

  private

  # rubocop:disable-next Metrics/AbcSize -- Keep synthetic certificate construction together.
  def material
    key = OpenSSL::PKey::RSA.new(2048)
    certificate = OpenSSL::X509::Certificate.new
    certificate.version = 2
    certificate.serial = 1
    certificate.subject = certificate.issuer = OpenSSL::X509::Name.parse('/CN=Empeira synthetic EYAML')
    certificate.public_key = key.public_key
    certificate.not_before = Time.now - 60
    certificate.not_after = Time.now + 3600
    certificate.sign(key, OpenSSL::Digest.new('SHA256'))
    [key, certificate]
  end

  def hierarchy
    destination = Empeira::Configuration::Eyaml::DESTINATION
    { 'version' => 5, 'defaults' => { 'datadir' => 'data' }, 'hierarchy' => [
      { 'name' => 'Synthetic encrypted data', 'lookup_key' => 'eyaml_lookup_key', 'path' => 'common.eyaml',
        'options' => { 'pkcs7_private_key' => "#{destination}/private_key.pkcs7.pem",
                       'pkcs7_public_key' => "#{destination}/public_key.pkcs7.pem" } }
    ] }
  end
end
