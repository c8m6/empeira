# frozen_string_literal: true

RSpec.describe 'EYAML server key mounts' do
  def configure(settings)
    File.write(File.join(@directory, '.empeira.yaml'), YAML.dump('eyaml' => settings))
    Empeira::Application.new(project_path: @directory)
  end

  it 'does not require key files when disabled' do
    app = configure('enabled' => false)
    expect(Empeira::ControlPlane::Plan.new(context: app.context).eyaml_mounts).to be_empty
  end

  it 'resolves relative and absolute files, mounts only the server read-only, and never reads their contents' do
    private_path = File.join(@directory, 'private.pem')
    public_path = File.join(@directory, 'public.pem')
    File.write(private_path, 'synthetic private material')
    File.write(public_path, 'synthetic certificate')
    private_path = File.realpath(private_path)
    app = configure('enabled' => true, 'private_key' => 'private.pem', 'public_key' => public_path)
    plan = Empeira::ControlPlane::Plan.new(context: app.context)
    expect(plan.eyaml_mounts).to include(
      "type=bind,src=#{private_path},dst=/etc/puppetlabs/puppet/eyaml/private_key.pkcs7.pem,readonly"
    )
    expect(plan.definitions.fetch('server').options['mounts']).to include(*plan.eyaml_mounts)
    plan.definitions.except('server').each_value do |definition|
      expect(definition.options.to_s).not_to include(private_path)
    end
    expect(plan.fingerprints.to_s + app.context.configuration.to_s).not_to include('synthetic private material')
    display = Empeira::Configuration::Display.redact(app.context.configuration)
    expect(display.dig('eyaml', 'private_key')).to eq('[REDACTED]')
    expect(display.to_s).not_to include('synthetic private material')
  end

  it 'stages Puppet Server keys outside its ownership sweep and keeps the documented paths in tmpfs' do
    private_path = File.join(@directory, 'private.pem')
    public_path = File.join(@directory, 'public.pem')
    File.write(private_path, 'synthetic private material')
    File.write(public_path, 'synthetic certificate')
    File.write(File.join(@directory, '.empeira.yaml'),
               YAML.dump('server' => { 'runtime' => { 'startup' => { 'eyaml_keys' => 'staged' } } },
                         'eyaml' => { 'enabled' => true, 'private_key' => private_path,
                                      'public_key' => public_path }))
    plan = Empeira::ControlPlane::Plan.new(context: Empeira::Application.new(project_path: @directory).context)
    server = plan.definitions.fetch('server').options

    expect(plan.eyaml_mounts).to include(
      "type=bind,src=#{File.realpath(private_path)},dst=/empeira-eyaml/private_key.pkcs7.pem,readonly"
    )
    expect(server.fetch('mounts')).to include(*plan.eyaml_mounts,
                                              'type=tmpfs,dst=/etc/puppetlabs/puppet/eyaml')
    expect(server.fetch('command')).to include('staged')
    expect(server.to_s).not_to include('synthetic private material')
  end

  it 'rejects absent, non-regular and unsafe files with the complete YAML path' do
    [nil, 'missing.pem', '.', 'bad,path', "bad\npath"].each do |value|
      expect { configure('enabled' => true, 'private_key' => value) }
        .to raise_error(Empeira::ConfigurationError, /eyaml.private_key/)
    end
  end

  it 'rejects unreadable key files without exposing contents' do
    path = Pathname(@directory).join('private.pem')
    path.write('synthetic private material')
    allow_any_instance_of(Pathname).to receive(:readable?).and_return(false)
    expect { configure('enabled' => true, 'private_key' => path.to_s) }
      .to raise_error(Empeira::ConfigurationError, /eyaml.private_key must be a readable regular file/)
  end
end
