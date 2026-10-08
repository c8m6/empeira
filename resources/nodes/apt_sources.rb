# frozen_string_literal: true

require 'pathname'
require 'uri'

module Empeira
  # Read-only bootstrap check. Repository management after bootstrap belongs to Puppet.
  class AptSources
    def initialize(root = '/')
      @root = Pathname(root)
    end

    def valid?
      release = @root.join('etc/os-release').read
      return true unless release.match?(/^ID=["']?(?:ubuntu|debian)["']?$/)

      apt = @root.join('etc/apt')
      lists = [apt.join('sources.list'), *apt.glob('sources.list.d/*.list')]
      lists.any? { |path| path.file? && legacy?(path.read) } ||
        apt.glob('sources.list.d/*.sources').any? { |path| deb822?(path.read) }
    end

    private

    def uri?(value)
      uri = URI.parse(value)
      %w[http https file].include?(uri.scheme) && (uri.scheme == 'file' || !uri.host.to_s.empty?)
    rescue URI::InvalidURIError
      false
    end

    def legacy?(content)
      content.lines.any? do |line|
        fields = line.sub(/#.*/, '').strip.sub(/\Adeb\s+\[[^\]]*\]\s+/, 'deb ').split
        fields.first == 'deb' && fields.length >= 4 && uri?(fields[1]) && fields.drop(3).include?('main')
      end
    end

    def deb822?(content)
      content.gsub(/^#.*\n?/, '').gsub(/\n[ \t]+/, ' ').split(/\n\s*\n/).any? do |paragraph|
        active?(fields(paragraph))
      end
    end

    def fields(paragraph)
      paragraph.lines.filter_map do |line|
        key, value = line.split(':', 2)
        [key.downcase, value.strip] if value
      end.to_h
    end

    def active?(fields)
      fields.fetch('enabled', 'yes').downcase != 'no' && fields.fetch('types', '').split.include?('deb') &&
        fields.fetch('uris', '').split.any? { |value| uri?(value) } &&
        !fields.fetch('suites', '').empty? && fields.fetch('components', '').split.include?('main')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    exit(Empeira::AptSources.new.valid? ? 0 : 1)
  rescue StandardError
    exit 1
  end
end
