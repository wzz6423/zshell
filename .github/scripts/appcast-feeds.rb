#!/usr/bin/env ruby
# frozen_string_literal: true

# Verifies that a published release is one an installed copy of Zshell can actually reach:
# the notarized DMG the website links, the update archive and notes Sparkle downloads, and
# the appcast that has to offer this version as the newest one. Parses the feed as text so
# CI needs no XML toolchain, and takes an injectable fetcher so the tests stay offline.

require 'optparse'
require 'net/http'
require 'uri'

module AppcastFeeds
  class VerificationError < StandardError; end

  REPOSITORY = 'wzz6423/zshell'
  # Sparkle resolves the whole feed against one prefix, so every archive it may ever offer
  # has to stay under one tag that never moves. That tag is the permanent `updates` release;
  # each version's DMG lives on its own `v<version>` release instead.
  UPDATES_TAG = 'updates'
  DOWNLOAD_ROOT = "https://github.com/#{REPOSITORY}/releases/download"
  UPDATES_PREFIX = "#{DOWNLOAD_ROOT}/#{UPDATES_TAG}/"
  FEED_URL = "#{UPDATES_PREFIX}appcast.xml"

  # release.ts creates the versioned release as v<CFBundleShortVersionString>, so the tag is
  # the version with a v in front and every asset name carries the bare version.
  TAG_PATTERN = /\Av(\d+(?:\.\d+)*(?:[-.+][0-9A-Za-z.-]+)?)\z/

  ITEM_PATTERN = %r{<item>(.*?)</item>}m
  ENCLOSURE_PATTERN = /<enclosure\b[^>]*>/
  URL_ATTRIBUTE = /\burl="([^"]*)"/
  SIGNATURE_ATTRIBUTE = /\bsparkle:edSignature="([^"]*)"/
  # generate_appcast writes the version fields as elements, which is also how the website
  # reads them (web/src/lib/release.ts). Both parsers have to agree on the same feed.
  BUILD_PATTERN = %r{<sparkle:version>([^<]*)</sparkle:version>}
  SHORT_VERSION_PATTERN = %r{<sparkle:shortVersionString>([^<]*)</sparkle:shortVersionString>}
  NOTES_LINK_PATTERN = %r{<sparkle:releaseNotesLink>([^<]*)</sparkle:releaseNotesLink>}

  def self.version_for(tag)
    match = TAG_PATTERN.match(tag.to_s)
    raise VerificationError, "#{tag} is not a v<version> release tag" if match.nil?

    match[1]
  end

  # Downloads the feed and reports either its body or why it could not be read.
  class HTTPFetcher
    def initialize(redirect_limit: 5, timeout: 20)
      @redirect_limit = redirect_limit
      @timeout = timeout
    end

    def call(url)
      remaining = @redirect_limit
      current = url
      while remaining.positive?
        response = get(current)
        return [response.code.to_i, response.body.to_s] unless response.is_a?(Net::HTTPRedirection)

        current = response['location']
        remaining -= 1
      end
      [0, "exceeded #{@redirect_limit} redirects starting at #{url}"]
    rescue StandardError => error
      # A release asset store that refuses the connection has to read as a verification
      # failure with a reason, not as a Ruby backtrace the release operator then decodes.
      [0, "#{error.class}: #{error.message}"]
    end

    private

    # Every request carries its own deadline so one hung endpoint cannot stall the run.
    def get(url)
      uri = URI.parse(url)
      Net::HTTP.start(
        uri.host, uri.port,
        use_ssl: uri.scheme == 'https', open_timeout: @timeout, read_timeout: @timeout
      ) { |http| http.request(Net::HTTP::Get.new(uri)) }
    end
  end

  class Verifier
    def initialize(tag:, fetcher:, feed_url: FEED_URL)
      @tag = tag
      @fetcher = fetcher
      @feed_url = feed_url
    end

    def run
      version = AppcastFeeds.version_for(@tag)
      status, body = @fetcher.call(@feed_url)
      return ["#{@feed_url} could not be read: #{body}"] if status.zero?
      return ["#{@feed_url} returned HTTP #{status}"] if status != 200

      items = body.scan(ITEM_PATTERN).flatten
      return ["#{@feed_url} carries no <item> elements"] if items.empty?

      errors = verify_prefix(body)
      errors.concat(verify_newest(items, version))
      errors.concat(verify_item(items, version))
    end

    private

    # One prefix covers every entry in the feed, including the ones for older versions, so a
    # prefix pointing anywhere but the permanent release breaks installs this release never
    # touched.
    def verify_prefix(body)
      urls = body.scan(ENCLOSURE_PATTERN).filter_map { |tag| tag[URL_ATTRIBUTE, 1] }
      urls.concat(body.scan(NOTES_LINK_PATTERN).flatten)
      urls.reject { |url| url.start_with?(UPDATES_PREFIX) }
          .map { |url| "#{@feed_url} serves #{url} from outside #{UPDATES_PREFIX}" }
    end

    # Sparkle offers the item with the highest build number, and the website reads that same
    # item to write its download link. A release whose build number did not move is published
    # but invisible: nobody is ever offered it.
    def verify_newest(items, version)
      newest = items.max_by { |item| item[BUILD_PATTERN, 1].to_i }
      offered = newest[SHORT_VERSION_PATTERN, 1].to_s.strip
      return [] if offered == version

      ["#{@feed_url} offers #{offered.empty? ? 'an item with no version' : offered} " \
       "as the newest update instead of #{version}"]
    end

    def verify_item(items, version)
      item = items.find { |candidate| candidate[SHORT_VERSION_PATTERN, 1].to_s.strip == version }
      return ["#{@feed_url} carries no item for #{version}"] if item.nil?

      errors = []
      errors << "#{@feed_url} carries no sparkle:version for #{version}" if item[BUILD_PATTERN, 1].to_s.strip.empty?
      errors.concat(verify_enclosure(item, version))
      errors.concat(verify_notes(item, version))
      errors
    end

    # The update has to be the archive published beside the appcast, signed with the key the
    # installed app pins. An unsigned enclosure downloads and then refuses to install.
    def verify_enclosure(item, version)
      expected = "#{UPDATES_PREFIX}zshell-#{version}.zip"
      enclosure = item.scan(ENCLOSURE_PATTERN).find { |tag| tag[URL_ATTRIBUTE, 1] == expected }
      return ["#{@feed_url} offers #{version} from somewhere other than #{expected}"] if enclosure.nil?
      return [] unless enclosure[SIGNATURE_ATTRIBUTE, 1].to_s.empty?

      ["#{@feed_url} carries no sparkle:edSignature for #{expected}"]
    end

    # generate_appcast only writes the link when the notes file sits beside the archive, so a
    # missing link means the version had no CHANGELOG.md section and shipped without notes.
    def verify_notes(item, version)
      expected = "#{UPDATES_PREFIX}zshell-#{version}.md"
      found = item[NOTES_LINK_PATTERN, 1]
      return ["#{@feed_url} carries no sparkle:releaseNotesLink for #{version}"] if found.nil?
      return [] if found == expected

      ["#{@feed_url} links the notes for #{version} at #{found} instead of #{expected}"]
    end
  end

  # What each release has to carry. An asset that never got uploaded is invisible on the
  # Release page yet 404s every download or update of it, so the list is checked as a set.
  def self.required_assets(tag:, layout:)
    version = version_for(tag)
    case layout
    when 'version' then ["zshell-#{version}.dmg"]
    when 'updates' then ['appcast.xml', "zshell-#{version}.zip", "zshell-#{version}.md"]
    else raise VerificationError, "unknown layout #{layout}"
    end
  end

  # Deltas, older archives and the source archives GitHub attaches are extra, never missing.
  def self.missing_assets(tag:, layout:, names:)
    required_assets(tag: tag, layout: layout) - names.map(&:strip).reject(&:empty?)
  end

  def self.main(argv)
    options = { layout: 'version' }
    parser = OptionParser.new do |opts|
      opts.banner = <<~USAGE
        usage: appcast-feeds.rb verify --tag vX.Y.Z
               appcast-feeds.rb verify-assets --tag vX.Y.Z [--layout version|updates] < asset-names
      USAGE
      opts.on('--tag TAG', 'release tag the feed must offer') { |value| options[:tag] = value }
      opts.on('--layout LAYOUT', 'version for the DMG release, updates for the feed release') do |value|
        options[:layout] = value
      end
    end
    parser.parse!(argv)
    command = argv.shift
    raise VerificationError, parser.banner unless %w[verify verify-assets].include?(command)
    raise VerificationError, 'a --tag is required' if options[:tag].to_s.empty?

    command == 'verify' ? verify_feed(options) : verify_assets(options)
  end

  def self.verify_feed(options)
    errors = Verifier.new(tag: options[:tag], fetcher: HTTPFetcher.new).run
    return report(errors) unless errors.empty?

    puts "#{FEED_URL} offers #{options[:tag]} as the newest update"
    0
  end

  def self.verify_assets(options)
    missing = missing_assets(tag: options[:tag], layout: options[:layout], names: $stdin.read.lines)
    return report(missing.map { |name| "the #{options[:layout]} release carries no #{name}" }) unless missing.empty?

    puts "the #{options[:layout]} release carries every asset #{options[:tag]} needs"
    0
  end

  def self.report(errors)
    errors.each { |error| warn "error: #{error}" }
    1
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    exit AppcastFeeds.main(ARGV)
  rescue AppcastFeeds::VerificationError => error
    warn error.message
    exit 1
  end
end
