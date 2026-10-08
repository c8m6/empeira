# frozen_string_literal: true

require 'empeira'

# Preloaded only by CLI subprocess tests: never read the developer's user preferences.
module IsolatedCLILocations
  def initialize(**)
    super(home: ENV.fetch('EMPEIRA_TEST_HOME'), **)
  end
end

Empeira::Platform::Locations.prepend(IsolatedCLILocations)
