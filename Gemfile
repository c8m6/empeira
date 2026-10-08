# frozen_string_literal: true

source 'https://rubygems.org'

gemspec

gem 'bundler-audit', '~> 0.9', require: false
gem 'rake', '~> 13.0'
gem 'rspec', '~> 3.13'
gem 'rubocop', '~> 1.75', require: false

# Exercise the actual isolated installer contract without container startup in normal CI.
eval_gemfile 'resources/modules/Gemfile'
