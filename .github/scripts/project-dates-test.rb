#!/usr/bin/env ruby
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'

require_relative 'project-dates'

class ProjectDatesTest < Minitest::Test
  def test_submission_date_uses_utc_plus_eight
    assert_equal({ 'submittedDate' => '2026-10-05', 'endDate' => nil },
                 ProjectDates.from_event(event))
  end

  def test_closed_issue_uses_its_close_day
    dates = ProjectDates.from_event(event(state: 'closed', closed_at: '2026-10-05T16:01:00Z'))

    assert_equal '2026-10-06', dates['endDate']
  end

  def test_merge_day_wins_over_close_day
    dates = ProjectDates.from_event(event(kind: 'pull_request', state: 'closed',
                                         closed_at: '2026-10-05T15:59:59Z', merged_at: '2026-10-05T16:01:00Z'))

    assert_equal '2026-10-06', dates['endDate']
  end

  def test_reopen_clears_end_day_even_with_a_stale_close_timestamp
    dates = ProjectDates.from_event(event(closed_at: '2026-10-05T16:01:00Z'))

    assert_nil dates['endDate']
  end

  def test_schedule_dates_are_supplied_only_by_pull_requests
    body = "## GitHub Project\n- Start date: 2026-10-01\n- Target date: 2026-10-10\n"
    dates = ProjectDates.from_event(event(kind: 'pull_request', body: body))

    assert_equal '2026-10-01', dates['startDate']
    assert_equal '2026-10-10', dates['targetDate']
    refute ProjectDates.from_event(event(body: body)).key?('startDate')
  end

  def test_blank_or_missing_schedule_is_omitted_to_preserve_board_values
    ['', "## GitHub Project\n- Start date: <!-- YYYY-MM-DD -->\n- Target date: \n"].each do |body|
      dates = ProjectDates.from_event(event(kind: 'pull_request', body: body))

      assert_equal %w[endDate submittedDate], dates.keys.sort
    end
  end

  def test_malformed_schedule_fails_as_a_contract_error
    error = assert_raises(ProjectDates::ContractError) do
      ProjectDates.from_event(event(kind: 'pull_request', body: "## GitHub Project\n- Start date: 2026-02-30\n"))
    end

    assert_includes error.message, 'Start date'
  end

  def test_missing_and_invalid_timestamps_fail
    assert_raises(ProjectDates::ContractError) { ProjectDates.from_event({}) }
    assert_raises(ProjectDates::ContractError) { ProjectDates.from_event(event(created_at: nil)) }
    assert_raises(ProjectDates::ContractError) { ProjectDates.from_event(event(state: 'closed')) }
    assert_raises(ProjectDates::ContractError) { ProjectDates.from_event(event(created_at: 'invalid')) }
  end

  def test_cli_returns_dates_and_rejects_invalid_input_without_json_output
    Dir.mktmpdir('zshell-project-dates-') do |directory|
      path = File.join(directory, 'event.json')
      File.write(path, JSON.generate(event))
      output, error, status = Open3.capture3('ruby', File.join(__dir__, 'project-dates.rb'), 'resolve', '--event-file', path)
      assert status.success?, error
      assert_equal '2026-10-05', JSON.parse(output)['submittedDate']

      File.write(path, JSON.generate(event(state: 'closed')))
      output, error, status = Open3.capture3('ruby', File.join(__dir__, 'project-dates.rb'), 'resolve', '--event-file', path)
      refute status.success?
      assert_empty output
      assert_includes error, 'completion timestamp'
    end
  end

  private

  def event(kind: 'issue', state: 'open', created_at: '2026-10-04T16:00:00Z', closed_at: nil, merged_at: nil, body: '')
    { kind => { 'state' => state, 'created_at' => created_at, 'closed_at' => closed_at,
                'merged_at' => merged_at, 'body' => body } }
  end
end
