# frozen_string_literal: true

require_relative 'base'

module Empeira
  module CLI
    class Update < Base
      Updates::Service::TARGETS.each do |target|
        desc target,
             { 'all' => 'Update all managed targets, including Empeira (unavailable)',
               'modules' => 'Synchronize Puppetfile module artifacts',
               'images' => 'Refresh configured container image artifacts' }.fetch(target)
        define_method(target) do
          if target == 'all'
            application.updates.update(target)
          else
            progressing("Updating #{target}...") { |app| app.updates.update(target) }
          end
        end
      end
    end
  end
end
