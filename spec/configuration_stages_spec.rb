# frozen_string_literal: true

RSpec.describe 'Configuration validation stages' do
  it 'accepts partial fragments but rejects incomplete effective configurations with full paths' do
    schema = Empeira::Configuration::Schema.new
    expect(schema.validate_fragment!({})).to eq({})
    expect(schema.validate_fragment!('node_defaults' => { 'cpus' => 4 })).to eq('node_defaults' => { 'cpus' => 4 })
    expect { schema.validate_effective!({}) }.to raise_error(Empeira::ConfigurationError, /version is required/)
    effective = Empeira::Configuration::Loader.new(project_path: @directory).load
    effective['node_defaults'].delete('memory')
    expect { schema.validate_effective!(effective) }.to raise_error(Empeira::ConfigurationError, /node_defaults.memory/)
  end

  it 'runs cross-field checks only after merging and validating a complete structure' do
    observed = []
    rule = ->(config) { observed << [config.dig('node_defaults', 'memory'), config.dig('node_defaults', 'cpus')] }
    schema = Empeira::Configuration::Schema.new(cross_field_rules: [rule])
    File.write(File.join(@directory, '.empeira.yaml'), 'node_defaults: {memory: 2048}')
    Empeira::Configuration::Loader.new(project_path: @directory, schema: schema)
                                  .load(overrides: { 'node_defaults' => { 'cpus' => 4 } })
    expect(observed).to eq([[2048, 4]])
  end

  it 'preserves actionable domain paths from cross-field rules' do
    rule = ->(_config) { raise Empeira::ConfigurationError, 'node_defaults.cpus conflicts with node_defaults.memory' }
    schema = Empeira::Configuration::Schema.new(cross_field_rules: [rule])
    expect { Empeira::Configuration::Loader.new(project_path: @directory, schema: schema).load }
      .to raise_error(Empeira::ConfigurationError, /node_defaults.cpus conflicts with node_defaults.memory/)
  end
end
