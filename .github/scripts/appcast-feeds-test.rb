#!/usr/bin/env ruby
# frozen_string_literal: true

require 'minitest/autorun'
require 'stringio'
require_relative 'appcast-feeds'

class AppcastFeedsTest < Minitest::Test
  TAG = 'v0.1.0'
  VERSION = '0.1.0'
  KEY = OpenSSL::PKey.generate_key('ED25519')

  def sign(xml)
    signature = Base64.strict_encode64(KEY.sign(nil, xml))
    "#{xml}<!-- sparkle-signatures:\nedSignature: #{signature}\nlength: #{xml.bytesize}\n-->\n"
  end

  def xml(host: 'github', architecture: 'universal', version: VERSION, build: '3', signature: Base64.strict_encode64('s' * 64))
    <<~XML
      <?xml version="1.0" encoding="utf-8"?>
      <rss version="2.0" xmlns:sparkle="#{AppcastFeeds::SPARKLE_NAMESPACE}">
        <channel><item>
          <title>Zshell 中文 #{version}</title>
          <sparkle:version>#{build}</sparkle:version>
          <sparkle:shortVersionString>#{version}</sparkle:shortVersionString>
          <enclosure url="https://#{host}.com/#{AppcastFeeds::REPOSITORY}/releases/download/v#{version}/zshell-v#{version}-macOS-#{architecture}.zip"
            length="1234" type="application/octet-stream" sparkle:edSignature="#{signature}" />
        </item></channel>
      </rss>
    XML
  end

  def feeds
    AppcastFeeds::FEED_ROOTS.each_with_object({}) do |(host, root), result|
      AppcastFeeds::ARCHIVES.each do |name, architecture|
        content = sign(xml(host: host, architecture: architecture))
        result["#{root}/#{name}"] = content
        result["https://gitee.com/#{AppcastFeeds::REPOSITORY}/releases/download/#{TAG}/#{name}"] = content if host == 'gitee'
      end
    end
  end

  def errors(bodies = feeds, hosts: AppcastFeeds::FEED_ROOTS.keys, tag: TAG)
    fetcher = bodies.respond_to?(:call) ? bodies : ->(url) { bodies.key?(url) ? [200, bodies.fetch(url)] : [404, ''] }
    AppcastFeeds::Verifier.new(tag: tag, fetcher: fetcher, hosts: hosts, public_key: KEY).run
  end

  def github_url(name = 'appcast.xml')
    "#{AppcastFeeds::FEED_ROOTS.fetch('github')}/#{name}"
  end

  def test_complete_six_signed_feeds_pass_with_utf8_content
    assert_empty errors
  end

  def test_missing_architecture_fails
    bodies = feeds
    bodies.delete(github_url('appcast-arm64.xml'))
    assert_includes errors(bodies).join, 'appcast-arm64.xml returned HTTP 404'
  end

  def test_cross_host_reference_fails_even_with_valid_xml_signature
    bodies = feeds.merge(github_url => sign(xml(host: 'gitee')))
    assert_includes errors(bodies).join, 'instead of https://github.com/'
  end

  def test_wrong_architecture_fails_even_with_valid_xml_signature
    bodies = feeds.merge(github_url => sign(xml(architecture: 'arm64')))
    assert_includes errors(bodies).join, 'instead of https://github.com/wzz6423/zshell/releases/download/v0.1.0/zshell-v0.1.0-macOS-universal.zip'
  end

  def test_wrong_version_fails
    bodies = feeds.merge(github_url => sign(xml(version: '0.0.1')))
    assert_includes errors(bodies).join, 'instead of 0.1.0'
  end

  def test_unsigned_xml_fails_even_when_zip_signature_exists
    assert_includes errors(feeds.merge(github_url => xml)).join, 'no outer sparkle-signatures XML signature'
  end

  def test_changed_signed_xml_fails
    assert_includes errors(feeds.merge(github_url => sign(xml).sub('Zshell', 'zshell'))).join, 'XML Ed25519 signature is invalid'
  end

  def test_incorrect_signed_length_fails
    assert_includes errors(feeds.merge(github_url => sign(xml).sub(/length: \d+/, 'length: 1'))).join, 'signature length does not match'
  end

  def test_malformed_xml_fails_even_with_valid_signature
    assert_match(/Missing end tag|Unexpected top-level end tag/, errors(feeds.merge(github_url => sign(xml.sub('</channel>', '')))).join)
  end

  def test_multiple_items_or_enclosures_fail
    assert_includes errors(feeds.merge(github_url => sign(xml.sub('</channel>', '<item/></channel>')))).join, 'release items instead of 1'
    assert_includes errors(feeds.merge(github_url => sign(xml.sub('</item>', '<enclosure/></item>')))).join, 'enclosures instead of 1'
  end

  def test_invalid_zip_signature_and_length_fail
    assert_includes errors(feeds.merge(github_url => sign(xml(signature: 'c2ln')))).join, '64-byte ZIP Ed25519 signature'
    assert_includes errors(feeds.merge(github_url => sign(xml.sub('length="1234"', 'length="0"')))).join, 'positive ZIP byte length'
  end

  def test_missing_or_non_numeric_build_fails
    %w[0 nope].each do |build|
      assert_includes errors(feeds.merge(github_url => sign(xml(build: build)))).join, 'positive sparkle:version'
    end
  end

  def test_gitee_permanent_and_versioned_appcasts_must_match
    bodies = feeds
    bodies["https://gitee.com/#{AppcastFeeds::REPOSITORY}/releases/download/#{TAG}/appcast.xml"] = 'old XML'
    assert_includes errors(bodies).join, 'version appcast'
  end

  def test_network_error_reports_reason_and_can_verify_github_only_explicitly
    assert_includes errors(->(_url) { [0, 'SocketError'] }).join, 'could not be read: SocketError'
    github_only = feeds.select { |url, _| url.start_with?('https://github.com/') }
    assert_empty errors(github_only, hosts: ['github'])
    refute_empty errors(github_only)
  end

  def test_unknown_hosts_and_nonstable_tags_are_rejected
    assert_raises(AppcastFeeds::VerificationError) { errors(hosts: []) }
    assert_raises(AppcastFeeds::VerificationError) { errors(hosts: ['example']) }
    %w[updates update-release preview v0.1.0-preview.1 release/v0.1.0].each do |tag|
      assert_raises(AppcastFeeds::VerificationError) { errors(tag: tag) }
    end
  end

  def test_version_requires_all_fifteen_assets_but_allows_legacy_assets
    required = AppcastFeeds.required_assets(tag: TAG, layout: 'version')
    assert_equal 15, required.length
    assert_empty AppcastFeeds.missing_assets(tag: TAG, layout: 'version', names: required + ['zshell-0.1.0.dmg'])
    assert_equal ['zshell-v0.1.0-macOS-x86_64.zip'], AppcastFeeds.missing_assets(tag: TAG, layout: 'version', names: required - ['zshell-v0.1.0-macOS-x86_64.zip'])
    assert_equal AppcastFeeds::ARCHIVES.keys, AppcastFeeds.required_assets(tag: TAG, layout: 'feed')
  end

  def test_feed_layout_rejects_extra_or_duplicate_assets
    previous_stdin = $stdin
    $stdin = StringIO.new((AppcastFeeds::ARCHIVES.keys + ['extra.zip']).join("\n"))
    _out, err = capture_io { assert_equal 1, AppcastFeeds.main(['verify-assets', '--tag', TAG, '--layout', 'feed']) }
    assert_includes err, 'unexpected permanent feed asset extra.zip'
  ensure
    $stdin = previous_stdin
  end

  def test_public_key_and_feed_urls_match_the_application
    assert AppcastFeeds.public_key
    plist = File.read(File.expand_path('../../mac/zshell/Info.plist', __dir__))
    assert_includes plist, "#{AppcastFeeds::FEED_ROOTS.fetch('gitee')}/appcast.xml"
    assert_includes plist, "#{AppcastFeeds::FEED_ROOTS.fetch('github')}/appcast.xml"
  end
end
