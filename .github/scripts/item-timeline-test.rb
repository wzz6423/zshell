#!/usr/bin/env ruby
# frozen_string_literal: true

require 'minitest/autorun'

require_relative 'item-timeline'

class ItemTimelineTest < Minitest::Test
  def test_open_issue_records_submission_and_pending_completion
    body = ItemTimeline.render(issue(state: 'open', created_at: '2026-10-04T01:02:03Z'))

    assert_includes body, '- Submitted: `2026-10-04 09:02:03 UTC+08:00`'
    assert_includes body, '- Completed: Pending'
  end

  def test_closed_issue_records_close_time
    body = ItemTimeline.render(
      issue(state: 'closed', created_at: '2026-10-04T01:02:03Z', closed_at: '2026-10-05T04:05:06Z')
    )

    assert_includes body, '- Completed: `2026-10-05 12:05:06 UTC+08:00` (closed)'
  end

  def test_merged_pull_request_prefers_merge_time
    body = ItemTimeline.render(
      pull_request(
        state: 'closed',
        created_at: '2026-10-04T01:02:03Z',
        closed_at: '2026-10-05T04:05:06Z',
        merged_at: '2026-10-05T03:04:05Z'
      )
    )

    assert_includes body, '- Completed: `2026-10-05 11:04:05 UTC+08:00` (merged)'
  end

  def test_reopened_content_clears_previous_completion
    body = ItemTimeline.render(
      pull_request(
        state: 'open',
        created_at: '2026-10-04T01:02:03Z',
        closed_at: '2026-10-05T04:05:06Z',
        merged_at: nil
      )
    )

    assert_includes body, '- Completed: Pending'
  end

  def test_timestamps_cross_midnight_in_utc_plus_eight
    body = ItemTimeline.render(issue(state: 'closed', created_at: '2026-10-04T16:00:00Z',
                                     closed_at: '2026-10-05T17:30:00Z'))

    assert_includes body, '- Submitted: `2026-10-05 00:00:00 UTC+08:00`'
    assert_includes body, '- Completed: `2026-10-06 01:30:00 UTC+08:00` (closed)'
  end

  def test_missing_completion_and_invalid_timestamps_fail
    assert_raises(ItemTimeline::ContractError) do
      ItemTimeline.render(issue(state: 'closed', created_at: '2026-10-04T01:02:03Z'))
    end
    assert_raises(ItemTimeline::ContractError) do
      ItemTimeline.render(issue(state: 'open', created_at: 'invalid'))
    end
  end

  def test_event_without_content_is_rejected
    error = assert_raises(ItemTimeline::ContractError) { ItemTimeline.render({}) }

    assert_equal 'event contains no Issue or pull request', error.message
  end

  private

  def issue(state:, created_at:, closed_at: nil)
    { 'issue' => { 'state' => state, 'created_at' => created_at, 'closed_at' => closed_at } }
  end

  def pull_request(state:, created_at:, closed_at:, merged_at:)
    {
      'pull_request' => {
        'state' => state,
        'created_at' => created_at,
        'closed_at' => closed_at,
        'merged_at' => merged_at
      }
    }
  end
end
