# frozen_string_literal: true

# External synthetic repositories exercise both Puppet-aware mount destinations.
class HieraFixture
  attr_reader :module_data, :environment_data

  def initialize(project:, directory:)
    @project = Pathname(project)
    @directory = Pathname(directory)
  end

  # rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength -- Construct two synthetic Hiera repositories and their shared hierarchy.
  def prepare
    mod = @directory.join('module-data')
    env = @directory.join('environment-data')
    FileUtils.mkdir_p(mod.join('data'))
    FileUtils.mkdir_p(env)
    @module_data = mod.join('data/common.yaml')
    @environment_data = env.join('external.yaml')
    module_data.write(YAML.dump('hieradata_smoke::value' => 'mounted-module'))
    environment_data.write(YAML.dump('external_value' => 'mounted-environment'))
    defaults = { 'datadir' => 'data', 'data_hash' => 'yaml_data' }
    mod.join('hiera.yaml').write(YAML.dump('version' => 5, 'defaults' => defaults,
                                           'hierarchy' => [{ 'name' => 'Common', 'path' => 'common.yaml' }]))
    hiera = YAML.safe_load(@project.join('hiera.yaml').read)
    hiera.fetch('hierarchy').push('name' => 'External environment data', 'path' => 'external/external.yaml',
                                  'data_hash' => 'yaml_data')
    @project.join('hiera.yaml').write(YAML.dump(hiera))
    { 'mounts' => [
      { 'source' => mod.to_s, 'type' => 'module', 'name' => 'hieradata_smoke', 'required' => true },
      { 'source' => env.to_s, 'type' => 'environment', 'target' => 'data/external', 'required' => true },
      { 'source' => @directory.join('unavailable').to_s, 'type' => 'module', 'name' => 'hieradata_unavailable' }
    ] }
  end
end
