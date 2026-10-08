# frozen_string_literal: true

require 'empeira'
require_relative 'commands'
require_relative 'assets'

puts SharedNetworkProof::Assets.new.prepare.directory
