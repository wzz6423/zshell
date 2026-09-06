#!/usr/bin/env ruby
# frozen_string_literal: true

# CI verifies public assets and signed canonical feeds. The publishing tool additionally
# downloads both hosts' binaries and verifies their hashes and ZIP Ed25519 signatures.
require 'base64'
require 'net/http'
require 'openssl'
require 'optparse'
require 'rexml/document'
require 'uri'

module AppcastFeeds
  class VerificationError < StandardError; end

  REPOSITORY = 'wzz6423/zshell'
  SPARKLE_NAMESPACE = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
  ARCHIVES = {
    'appcast.xml' => 'universal',
    'appcast-arm64.xml' => 'arm64',
    'appcast-x86_64.xml' => 'x86_64'
  }.freeze
  FEED_ROOTS = {
    'gitee' => "https://gitee.com/#{REPOSITORY}/releases/download/update-release",
    'github' => "https://github.com/#{REPOSITORY}/releases/latest/download"
  }.freeze

  def self.version_for(tag)
    match = /\Av(\d+\.\d+\.\d+)\z/.match(tag.to_s)
    raise VerificationError, "#{tag} is not a stable vX.Y.Z release tag" unless match

    match[1]
  end

  def self.public_key
    plist = File.read(File.expand_path('../../mac/zshell/Info.plist', __dir__))
    encoded = plist[%r{<key>SUPublicEDKey</key>\s*<string>([^<]+)</string>}, 1]
    bytes = Base64.strict_decode64(encoded.to_s)
    raise VerificationError, 'SUPublicEDKey must contain 32 bytes' unless bytes.bytesize == 32

    OpenSSL::PKey.read(['302a300506032b6570032100'].pack('H*') + bytes)
  end

  class HTTPFetcher
    def initialize(redirect_limit: 5, timeout: 20)
      @redirect_limit = redirect_limit
      @timeout = timeout
    end

    def call(url)
      current = URI.parse(url)
      @redirect_limit.times do
        raise VerificationError, 'only HTTPS downloads are accepted' unless current.scheme == 'https'

        response = Net::HTTP.start(current.host, current.port, use_ssl: true,
                                  open_timeout: @timeout, read_timeout: @timeout) do |http|
          http.request(Net::HTTP::Get.new(current))
        end
        return [response.code.to_i, response.body.to_s] unless response.is_a?(Net::HTTPRedirection)

        current = URI.join(current.to_s, response.fetch('location'))
      end
      [0, "exceeded #{@redirect_limit} redirects starting at #{url}"]
    rescue StandardError => error
      [0, "#{error.class}: #{error.message}"]
    end
  end

  class Verifier
    def initialize(tag:, fetcher:, hosts: FEED_ROOTS.keys, public_key: AppcastFeeds.public_key)
      @tag = tag
      @version = AppcastFeeds.version_for(tag)
      @fetcher = fetcher
      @hosts = hosts
      @public_key = public_key
    end

    def run
      unknown = @hosts - FEED_ROOTS.keys
      raise VerificationError, "unknown hosts #{unknown.join(', ')}" unless unknown.empty?
      raise VerificationError, 'at least one host is required' if @hosts.empty?

      @hosts.flat_map do |host|
        ARCHIVES.flat_map { |name, architecture| verify_feed(host, name, architecture) }
      end
    end

    private

    def verify_feed(host, name, architecture)
      url = "#{FEED_ROOTS.fetch(host)}/#{name}"
      status, body = @fetcher.call(url)
      return ["#{url} could not be read: #{body}"] if status.zero?
      return ["#{url} returned HTTP #{status}"] if status != 200

      content = signed_content(body)
      document = REXML::Document.new(content)
      namespaces = { 'sparkle' => SPARKLE_NAMESPACE }
      items = REXML::XPath.match(document, '/rss/channel/item')
      raise VerificationError, "carries #{items.length} release items instead of 1" unless items.length == 1

      item = items.first
      short_version = REXML::XPath.first(item, 'sparkle:shortVersionString', namespaces)&.text
      raise VerificationError, "offers #{short_version.inspect} instead of #{@version}" unless short_version == @version

      build = REXML::XPath.first(item, 'sparkle:version', namespaces)&.text.to_s
      raise VerificationError, 'carries no positive sparkle:version build number' unless /\A[1-9]\d*\z/.match?(build)

      enclosures = REXML::XPath.match(document, '//enclosure')
      raise VerificationError, "carries #{enclosures.length} enclosures instead of 1" unless enclosures.length == 1 && enclosures.first.parent == item

      enclosure = enclosures.first
      expected = "https://#{host}.com/#{REPOSITORY}/releases/download/#{@tag}/zshell-#{@tag}-macOS-#{architecture}.zip"
      raise VerificationError, "points at #{enclosure.attributes['url'].inspect} instead of #{expected}" unless enclosure.attributes['url'] == expected
      raise VerificationError, 'carries no positive ZIP byte length' unless /\A[1-9]\d*\z/.match?(enclosure.attributes['length'].to_s)

      signature = enclosure.attributes.get_attribute_ns(SPARKLE_NAMESPACE, 'edSignature')&.value.to_s
      raise VerificationError, 'carries no valid 64-byte ZIP Ed25519 signature' unless decode_signature(signature)&.bytesize == 64

      # Gitee serves the canonical feed from a separate permanent release. Its version
      # release must carry those exact signed bytes, not an older or edited appcast.
      if host == 'gitee'
        version_url = "https://gitee.com/#{REPOSITORY}/releases/download/#{@tag}/#{name}"
        version_status, version_body = @fetcher.call(version_url)
        raise VerificationError, "version appcast #{version_url} differs or is unavailable (HTTP #{version_status})" unless version_status == 200 && version_body.b == body.b
      end
      []
    rescue VerificationError, REXML::ParseException, OpenSSL::PKey::PKeyError => error
      ["#{url}: #{error.message}"]
    end

    def signed_content(body)
      bytes = body.b
      signing = /<!-- sparkle-signatures:\nedSignature: ([A-Za-z0-9+\/=]+)\nlength: (\d+)\n-->\n?\z/.match(bytes)
      raise VerificationError, 'carries no outer sparkle-signatures XML signature' unless signing

      length = signing[2].to_i
      raise VerificationError, 'XML signature length does not match signed content' unless length == signing.begin(0)

      content = bytes.byteslice(0, length)
      signature = decode_signature(signing[1])
      raise VerificationError, 'XML Ed25519 signature is invalid' unless signature&.bytesize == 64 && @public_key.verify(nil, signature, content)
      raise VerificationError, 'XML entity declarations are forbidden' if /<!DOCTYPE|<!ENTITY/i.match?(content)

      content
    end

    def decode_signature(value)
      Base64.strict_decode64(value)
    rescue ArgumentError
      nil
    end
  end

  def self.required_assets(tag:, layout:)
    return ARCHIVES.keys if layout == 'feed'
    raise VerificationError, "unknown layout #{layout}" unless layout == 'version'

    version_for(tag)
    ARCHIVES.keys + ARCHIVES.values.flat_map do |architecture|
      %w[dmg dmg.sha256 zip zip.sha256].map { |extension| "zshell-#{tag}-macOS-#{architecture}.#{extension}" }
    end
  end

  def self.missing_assets(tag:, layout:, names:)
    required_assets(tag: tag, layout: layout) - names.map(&:strip).reject(&:empty?)
  end

  def self.main(argv)
    options = { hosts: FEED_ROOTS.keys, layout: 'version' }
    parser = OptionParser.new do |opts|
      opts.banner = <<~USAGE
        usage: appcast-feeds.rb verify --tag vX.Y.Z [--hosts gitee,github]
               appcast-feeds.rb verify-assets --tag vX.Y.Z [--layout version|feed] < asset-names
      USAGE
      opts.on('--tag TAG') { |value| options[:tag] = value }
      opts.on('--hosts LIST') { |value| options[:hosts] = value.split(',').map(&:strip).reject(&:empty?) }
      opts.on('--layout LAYOUT') { |value| options[:layout] = value }
    end
    parser.parse!(argv)
    command = argv.shift
    raise VerificationError, parser.banner unless %w[verify verify-assets].include?(command)
    raise VerificationError, 'a --tag is required' if options[:tag].to_s.empty?

    if command == 'verify'
      errors = Verifier.new(tag: options[:tag], hosts: options[:hosts], fetcher: HTTPFetcher.new).run
    else
      names = $stdin.read.lines.map(&:strip).reject(&:empty?)
      required = required_assets(tag: options[:tag], layout: options[:layout])
      errors = (required - names).map { |name| "the #{options[:layout]} release carries no #{name}" }
      errors.concat((names - required).map { |name| "unexpected permanent feed asset #{name}" }) if options[:layout] == 'feed'
      errors.concat(required.select { |name| names.count(name) > 1 }.map { |name| "duplicate asset #{name}" })
    end
    errors.each { |error| warn "error: #{error}" }
    puts "Verified #{options[:tag]} #{command} on #{options[:hosts].join(', ')}" if errors.empty?
    errors.empty? ? 0 : 1
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    exit AppcastFeeds.main(ARGV)
  rescue AppcastFeeds::VerificationError, OptionParser::ParseError => error
    warn error.message
    exit 1
  end
end
