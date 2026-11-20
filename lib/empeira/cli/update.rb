# frozen_string_literal: true

require_relative 'base'

module Empeira
  module CLI
    class Update < Base
      Updates::Service::TARGETS.each do |target|
        desc target,
             { 'all' => 'Update Empeira, then images and modules using the updated installation',
               'modules' => 'Synchronize Puppetfile module artifacts',
               'images' => 'Refresh configured container image artifacts' }.fetch(target)
        define_method(target) do
          if target == 'all'
            say 'Updating Empeira, images and modules...'
            Updates::Service.new.update(target)
          else
            progressing("Updating #{target}...") { |app| app.updates.update(target) }
          end
        end
      end
    end
  end
end
