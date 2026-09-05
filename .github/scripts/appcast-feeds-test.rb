#!/usr/bin/env ruby
# frozen_string_literal: true

require 'minitest/autorun'
require 'pathname'

require_relative 'appcast-feeds'

class AppcastFeedsTest < Minitest::Test
  TAG = 'v0.2.0'
  VERSION = '0.2.0'
  PREVIOUS = '0.1.0'
  PREFIX = AppcastFeeds::UPDATES_PREFIX

  # Serves whatever body each URL is mapped to, so the assertions never touch the network.
  class StubFetcher
    def initialize(bodies)
      @bodies = bodies
    end

    def call(url)
      body = @bodies[url]
      body.nil? ? [404, ''] : [200, body]
    end
  end

  def item(version:, build:, prefix: PREFIX, signature: 'c2lnbmF0dXJl', notes: :default, deltas: [], archive: :default)
    notes = "#{prefix}zshell-#{version}.md" if notes == :default
    archive = "zshell-#{version}.zip" if archive == :default
    <<~XML
      <item>
        <title>#{version}</title>
        <sparkle:version>#{build}</sparkle:version>
        <sparkle:shortVersionString>#{version}</sparkle:shortVersionString>
        #{notes.nil? ? '' : "<sparkle:releaseNotesLink>#{notes}</sparkle:releaseNotesLink>"}
        <enclosure url="#{prefix}#{archive}" length="1234"
          type="application/octet-stream" sparkle:edSignature="#{signature}" />
        #{deltas.empty? ? '' : deltas.map { |from| delta(from: from, to: version, prefix: prefix) }.join}
      </item>
    XML
  end

  def delta(from:, to:, prefix: PREFIX)
    <<~XML
      <sparkle:deltas>
        <enclosure url="#{prefix}zshell-#{from}-#{to}.delta" sparkle:deltaFrom="#{from}"
          length="12" type="application/octet-stream" sparkle:edSignature="ZGVsdGE=" />
      </sparkle:deltas>
    XML
  end

  def feed(*items)
    <<~XML
      <?xml version="1.0" encoding="utf-8"?>
      <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
        <channel>
          <title>zshell</title>
      #{items.join}
        </channel>
      </rss>
    XML
  end

  # What a healthy release looks like: the new version outranks the one before it by build
  # number and ships a delta from it.
  def complete_feed
    feed(item(version: PREVIOUS, build: 10), item(version: VERSION, build: 11, deltas: [PREVIOUS]))
  end

  def errors(body, tag: TAG)
    fetcher = body.respond_to?(:call) ? body : StubFetcher.new(AppcastFeeds::FEED_URL => body)
    AppcastFeeds::Verifier.new(tag: tag, fetcher: fetcher).run
  end

  def test_a_complete_feed_passes
    assert_empty errors(complete_feed)
  end

  def test_a_feed_that_answers_404_is_reported
    assert_includes errors(nil).join("\n"), 'returned HTTP 404'
  end

  # An endpoint that never answers has to fail with its reason attached, or the release
  # operator is left guessing whether the release or the network is broken.
  def test_an_unreachable_feed_reports_the_reason
    unreachable = ->(_url) { [0, 'SocketError: getaddrinfo failed'] }
    assert_includes errors(unreachable).join("\n"), 'could not be read: SocketError'
  end

  def test_an_empty_feed_is_reported
    assert_includes errors(feed).join("\n"), 'carries no <item> elements'
  end

  # The failure the two-release layout exists to prevent: enclosures written against a tag
  # that moves, which breaks every install the feed has ever served.
  def test_a_feed_served_from_another_tag_is_reported
    moved = feed(item(version: VERSION, build: 11, prefix: "#{AppcastFeeds::DOWNLOAD_ROOT}/#{TAG}/"))
    assert_includes errors(moved).join("\n"), "from outside #{PREFIX}"
  end

  def test_a_delta_served_from_another_tag_is_reported
    body = feed(
      item(version: VERSION, build: 11) +
      delta(from: PREVIOUS, to: VERSION, prefix: "#{AppcastFeeds::DOWNLOAD_ROOT}/#{TAG}/")
    )
    assert_includes errors(body).join("\n"), "from outside #{PREFIX}"
  end

  # Sparkle ranks items by build number, so a release that forgot to bump
  # CURRENT_PROJECT_VERSION is published and yet never offered to anyone.
  def test_a_release_that_does_not_outrank_the_previous_one_is_reported
    stale = feed(item(version: PREVIOUS, build: 12), item(version: VERSION, build: 11))
    assert_includes errors(stale).join("\n"), "as the newest update instead of #{VERSION}"
  end

  def test_a_feed_without_this_version_is_reported
    assert_includes errors(feed(item(version: PREVIOUS, build: 10))).join("\n"), "carries no item for #{VERSION}"
  end

  # The archive release.ts uploads is the one the feed has to point at; a name that drifted
  # from it downloads nothing even though the release page looks complete.
  def test_an_archive_under_another_name_is_reported
    renamed = feed(item(version: VERSION, build: 11, archive: "zshell-#{VERSION}-universal.zip"))
    assert_includes errors(renamed).join("\n"), "offers #{VERSION} from somewhere other than"
  end

  def test_an_unsigned_update_is_reported
    unsigned = feed(item(version: VERSION, build: 11, signature: ''))
    assert_includes errors(unsigned).join("\n"), 'carries no sparkle:edSignature'
  end

  # No notes link means the version had no CHANGELOG.md section, so the update prompt would
  # offer an install with nothing to read.
  def test_an_update_without_release_notes_is_reported
    assert_includes errors(feed(item(version: VERSION, build: 11, notes: nil))).join("\n"),
                    'carries no sparkle:releaseNotesLink'
  end

  def test_notes_for_another_version_are_reported
    crossed = feed(item(version: VERSION, build: 11, notes: "#{PREFIX}zshell-#{PREVIOUS}.md"))
    assert_includes errors(crossed).join("\n"), "links the notes for #{VERSION} at #{PREFIX}zshell-#{PREVIOUS}.md"
  end

  def test_a_feed_item_without_a_build_number_is_reported
    assert_includes errors(feed(item(version: VERSION, build: ''))).join("\n"), 'carries no sparkle:version'
  end

  def test_a_tag_that_carries_no_version_is_rejected
    assert_raises(AppcastFeeds::VerificationError) { errors(complete_feed, tag: AppcastFeeds::UPDATES_TAG) }
    assert_raises(AppcastFeeds::VerificationError) { errors(complete_feed, tag: "release/#{TAG}") }
  end

  def test_a_prerelease_tag_is_accepted
    assert_equal '0.2.0-beta.1', AppcastFeeds.version_for('v0.2.0-beta.1')
  end

  # The verifier has to check the feed an installed copy actually asks for; if SUFeedURL
  # moves and this does not, the gate keeps passing against an abandoned URL.
  def test_the_feed_url_is_the_one_the_app_pins
    plist = repository_file('mac/zshell/Info.plist')
    assert_equal AppcastFeeds::FEED_URL, plist[%r{<key>SUFeedURL</key>\s*<string>([^<]+)</string>}, 1]
  end

  # release.ts writes the feed against this prefix; if it moves, every URL in the feed moves
  # with it and the verifier would be checking a URL nothing publishes any more.
  def test_the_updates_tag_is_the_one_release_ts_publishes_to
    source = repository_file('mac/scripts/lib.ts')
    assert_includes source, "UPDATES_TAG = process.env.UPDATES_TAG ?? \"#{AppcastFeeds::UPDATES_TAG}\""
    assert_includes source, "https://github.com/${RELEASE_REPO}/releases/download/${tag}/"
  end

  # The website reads the same feed to write its download button.
  def test_the_feed_url_is_the_one_the_website_reads
    source = repository_file('web/src/lib/release.ts')
    assert_includes source, "/releases/download/#{AppcastFeeds::UPDATES_TAG}/appcast.xml"
    assert_includes source, "/releases/download/v${version}/zshell-${version}.dmg"
  end

  def assets(layout: 'version', tag: TAG)
    AppcastFeeds.required_assets(tag: tag, layout: layout)
  end

  def missing(names, layout: 'version')
    AppcastFeeds.missing_assets(tag: TAG, layout: layout, names: names)
  end

  def test_the_version_release_carries_the_notarized_download
    assert_equal ["zshell-#{VERSION}.dmg"], assets
    assert_empty missing(assets)
    assert_equal ["zshell-#{VERSION}.dmg"], missing([])
  end

  def test_the_updates_release_carries_the_feed_the_archive_and_the_notes
    expected = ['appcast.xml', "zshell-#{VERSION}.zip", "zshell-#{VERSION}.md"]
    assert_equal expected.sort, assets(layout: 'updates').sort
    assert_empty missing(assets(layout: 'updates'), layout: 'updates')
    assert_equal ["zshell-#{VERSION}.md"], missing(['appcast.xml', "zshell-#{VERSION}.zip"], layout: 'updates')
  end

  # Deltas, the archives of older versions and the source archives GitHub attaches on its own
  # all live beside the required assets.
  def test_history_deltas_and_source_archives_do_not_count_as_missing
    extra = assets(layout: 'updates') + [
      "zshell-#{PREVIOUS}.zip", "zshell-#{PREVIOUS}-#{VERSION}.delta", "zshell-#{TAG}.tar.gz"
    ]
    assert_empty missing(extra, layout: 'updates')
  end

  def test_unknown_layout_is_rejected
    assert_raises(AppcastFeeds::VerificationError) { assets(layout: 'preview') }
  end

  # gh release view emits one name per line, so trailing newlines must not read as names.
  def test_asset_names_are_read_from_untrimmed_lines
    lines = assets(layout: 'updates').map { |name| "#{name}\n" } + ["\n", "  \n"]
    assert_empty missing(lines, layout: 'updates')
  end

  private

  def repository_file(path)
    Pathname.new(__dir__).join('../..', path).read(encoding: 'UTF-8')
  end
end
