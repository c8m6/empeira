# frozen_string_literal: true

# Run the normal CLI with fixture-only location injection, without changing the host home.
repository, fixture_home, engine, hostname = ARGV
require File.join(repository, 'lib/empeira')
require File.join(repository, 'lib/empeira/cli/main')
Empeira::CLI::Base.class_eval do
  no_commands do
    define_method(:application) do |node: false, progress: Empeira::Progress.new, recovery: false|
      locations = Empeira::Platform::Locations.new(home: fixture_home,
                                                   environment: { 'XDG_CACHE_HOME' => File.join(Dir.home, '.cache') })
      overrides = { 'runtime' => { 'container_engine' => engine } }
      overrides = Empeira::Configuration::Merge.call(overrides, node_overrides) if node
      Empeira::Application.new(project_path: Dir.pwd, locations: locations, overrides: overrides,
                               progress: progress, recovery: recovery)
    end
  end
end
begin
  Empeira::CLI::Main.start(['node', 'puppet', hostname])
rescue Empeira::Error => e
  warn e.message
  exit 1
end
