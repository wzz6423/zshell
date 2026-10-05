#!/usr/bin/env ruby
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'

require_relative 'pr-metadata'

class PullRequestMetadataTest < Minitest::Test
  CONTRACT_PATH = File.expand_path('../pr-automation.json', __dir__)

  def setup
    @contract = PullRequestMetadata::Contract.load(CONTRACT_PATH)
  end

  def test_accepts_a_complete_body
    assert_empty validate('ci(github): add pull request automation')
  end

  def test_reports_missing_sections
    errors = PullRequestMetadata.validate(title: 'ci: add automation', body: "## Summary\n\n- Work.\n", contract: @contract)

    assert_includes errors.join("\n"), '## PR Type'
    assert_includes errors.join("\n"), '## AI Attribution'
  end

  def test_rejects_a_non_conventional_title
    assert_includes validate('add automation').join("\n"), 'Conventional Commit'
  end

  def test_rejects_a_non_ascii_title
    assert_includes validate('ci: 增加自动化').join("\n"), 'Conventional Commit'
  end

  def test_rejects_a_type_that_disagrees_with_the_title
    errors = validate('fix(github): add pull request automation')

    assert_includes errors.join("\n"), 'does not match the title type'
  end

  def test_rejects_an_unknown_type
    errors = validate('ci: add automation', type: 'hotfix')

    assert_includes errors.join("\n"), 'is not allowed'
  end

  def test_rejects_more_than_one_type
    errors = validate('ci: add automation', type: "ci\n- Type: fix")

    assert_includes errors.join("\n"), 'exactly one'
  end

  def test_requires_the_configured_github_project
    assert_includes validate('ci: add automation', project: '').join("\n"), 'GitHub Project must declare exactly one'
    assert_includes validate('ci: add automation', project: 'another project').join("\n"), 'must be "zshell Development"'
    assert_empty validate('ci: add automation')
  end

  def test_project_dates_accept_calendar_dates_and_ignore_other_sections
    body = build_body(schedule: "- Start date: 2024-02-29\n- Target date: 2026-10-10")
    body += "\n## Notes\n- Start date: invalid\n"
    sections = PullRequestMetadata.sections(body)

    assert_equal({ 'startDate' => '2024-02-29', 'targetDate' => '2026-10-10' },
                 PullRequestMetadata.project_dates(sections['GitHub Project']))
    assert_empty PullRequestMetadata.validate(title: 'ci: add automation', body: body, contract: @contract)
  end

  def test_project_date_parsing_accepts_historical_missing_dates_and_template_comments
    [nil, [], ['- Start date:', '- Target date:   ']].each do |lines|
      assert_equal({ 'startDate' => nil, 'targetDate' => nil }, PullRequestMetadata.project_dates(lines))
    end
    body = "## GitHub Project\r\n- Start date: <!-- YYYY-MM-DD -->\r\n- Target date: 2026-10-10 <!-- plan -->\r\n<!--\r\n- Start date: invalid\r\n-->\r\n"

    assert_equal({ 'startDate' => nil, 'targetDate' => '2026-10-10' },
                 PullRequestMetadata.project_dates(PullRequestMetadata.sections(body)['GitHub Project']))
  end

  def test_validation_requires_both_project_dates
    assert_includes validate('ci: add automation', schedule: nil).join("\n"), 'non-empty Start date'
    ['Start date', 'Target date'].each do |field|
      other_field = field == 'Start date' ? 'Target date' : 'Start date'
      errors = validate('ci: add automation', schedule: "- #{other_field}: 2026-10-10")

      assert_includes errors.join("\n"), "non-empty #{field}"
    end
  end

  def test_validation_rejects_blank_or_template_placeholder_dates
    ['Start date', 'Target date'].product(['', '   ', '<!-- YYYY-MM-DD -->']).each do |field, value|
      other_field = field == 'Start date' ? 'Target date' : 'Start date'
      schedule = "- #{other_field}: 2026-10-10\n- #{field}: #{value}"
      errors = validate('ci: add automation', schedule: schedule)

      assert_includes errors.join("\n"), "non-empty #{field}"
    end
  end

  def test_json_cli_preserves_historical_missing_or_blank_dates
    Dir.mktmpdir('zshell-pr-metadata-') do |directory|
      path = File.join(directory, 'body.md')
      [nil, "- Start date: <!-- YYYY-MM-DD -->\n- Target date:   "].each do |schedule|
        File.write(path, build_body(schedule: schedule))
        output, error, status = Open3.capture3('ruby', File.join(__dir__, 'pr-metadata.rb'), 'json', '--body-file', path)

        assert status.success?, error
        assert_nil JSON.parse(output)['startDate']
        assert_nil JSON.parse(output)['targetDate']
      end
    end
  end

  def test_project_dates_reject_invalid_calendar_dates_formats_and_untrusted_values
    invalid = ['2026-02-29', '2026-02-30', '2026-13-01', '2026-00-01', '2026-10-00',
               '2026-4-1', '20261005', '2026-W41-1', '2026-278', '2026-10-05T00:00:00Z',
               'tomorrow', '2026-10-05; $(id)', '2026-10-05`id`', '2026-10-05\\nextra']
    ['Start date', 'Target date'].product(invalid).each do |field, value|
      schedule = "- Start date: 2026-10-01\n- Target date: 2026-10-10".sub(/^- #{field}:.*$/, "- #{field}: #{value}")
      errors = validate('ci: add automation', schedule: schedule)

      assert_includes errors.join("\n"), "#{field} must be a valid date in YYYY-MM-DD format.", value
    end
  end

  def test_project_dates_reject_duplicate_values
    ['Start date', 'Target date'].each do |field|
      schedule = "- Start date: 2026-10-01\n- Target date: 2026-10-10\n- #{field}: 2026-10-10"
      errors = validate('ci: add automation', schedule: schedule)

      assert_includes errors.join("\n"), "at most one #{field} entry"
    end
  end

  def test_project_dates_reject_duplicate_blank_entries
    ['Start date', 'Target date'].product(['', '2026-10-01']).each do |field, value|
      other_field = field == 'Start date' ? 'Target date' : 'Start date'
      schedule = "- #{other_field}: 2026-10-10\n- #{field}:\n- #{field}: #{value}"
      errors = validate('ci: add automation', schedule: schedule)

      assert_includes errors.join("\n"), "at most one #{field} entry"
    end
  end

  def test_json_cli_exports_schedule_and_fails_without_output_for_invalid_dates
    Dir.mktmpdir('zshell-pr-metadata-') do |directory|
      path = File.join(directory, 'body.md')
      File.write(path, build_body)
      output, error, status = Open3.capture3('ruby', File.join(__dir__, 'pr-metadata.rb'), 'json', '--body-file', path)
      assert status.success?, error
      assert_equal '2026-10-01', JSON.parse(output)['startDate']
      assert_equal '2026-10-10', JSON.parse(output)['targetDate']

      File.write(path, build_body(schedule: "- Start date: 2026-02-30\n- Target date: 2026-10-10"))
      output, error, status = Open3.capture3('ruby', File.join(__dir__, 'pr-metadata.rb'), 'json', '--body-file', path)
      refute status.success?
      assert_empty output
      assert_includes error, 'Start date must be a valid date'
    end
  end

  def test_requires_validation_status_and_fields
    assert_includes validate('ci: add automation', validation: '- Status: skipped').join("\n"), 'one exact status'
    assert_includes validate('ci: add automation', validation: '- Status: passed').join("\n"), 'non-empty Command'
    assert_includes validate('ci: add automation', validation: "- Status: passed\n- Command: rake").join("\n"), 'non-empty Result'
    assert_includes validate('ci: add automation', validation: '- Status: not run').join("\n"), 'non-empty Reason'
    assert_empty validate('ci: add automation', validation: "- Status: not run\n- Reason: No runnable target.")
  end

  def test_ignores_template_comments_when_reading_fields
    assert_includes validate('ci: add automation', validation: "- Status: passed\n- Command: <!-- required -->").join("\n"), 'non-empty Command'
  end

  def test_related_issue_accepts_a_closing_keyword
    metadata = parse(related: 'Closes #123')

    assert_equal [123], metadata['issues']
    assert_includes PullRequestMetadata.labels(metadata, @contract), 'development'
    assert_empty validate('ci: add automation', related: 'Closes #123')
  end

  def test_related_issue_accepts_a_closing_url
    metadata = parse(related: 'Fixes https://github.com/wzz6423/zshell/issues/42')

    assert_equal [42], metadata['issues']
  end

  def test_related_issue_ignores_a_bare_reference
    assert_includes validate('ci: add automation', related: 'See #123').join("\n"), 'closing keyword'
  end

  def test_related_issue_rejects_none_together_with_a_reference
    errors = validate('ci: add automation', related: "None\nCloses #7")

    assert_includes errors.join("\n"), 'cannot be both'
  end

  def test_related_issue_without_an_issue_has_no_development_label
    refute_includes PullRequestMetadata.labels(parse, @contract), 'development'
  end

  def test_declared_agent_requires_a_coauthor_trailer
    attribution = '- Agent: Claude Code (claude-opus-5)'

    assert_includes validate('ci: add automation', attribution: attribution).join("\n"), 'Co-authored-by'
  end

  def test_declared_agent_with_a_trailer_adds_the_ai_label
    attribution = "- Agent: Claude Code (claude-opus-5)\n- Co-authored-by: Claude <noreply@anthropic.com>"
    metadata = parse(attribution: attribution)

    assert_equal 'Claude Code (claude-opus-5)', metadata['agent']
    assert_equal ['Claude <noreply@anthropic.com>'], metadata['coAuthors']
    assert_includes PullRequestMetadata.labels(metadata, @contract), 'ai-assisted'
    assert_empty validate('ci: add automation', attribution: attribution)
  end

  def test_rejects_a_malformed_coauthor_trailer
    attribution = "- Agent: Claude Code\n- Co-authored-by: Claude"

    assert_includes validate('ci: add automation', attribution: attribution).join("\n"), 'Name <email>'
  end

  def test_rejects_a_coauthor_trailer_without_an_agent
    attribution = "- Agent: None\n- Co-authored-by: Claude <noreply@anthropic.com>"

    assert_includes validate('ci: add automation', attribution: attribution).join("\n"), 'Agent: None'
  end

  def test_requires_an_agent_field
    assert_includes validate('ci: add automation', attribution: '- Author: human').join("\n"), '- Agent:'
  end

  def test_agent_none_needs_no_trailer
    assert_empty validate('ci: add automation', attribution: '- Agent: none')
    assert_nil parse(attribution: '- Agent: none')['agent']
  end

  def test_repository_template_needs_only_its_own_fields_filled_in
    template = File.read(File.expand_path('../PULL_REQUEST_TEMPLATE.md', __dir__))
                   .sub(/^- Type:$/, '- Type: ci')
                   .sub(/^- Start date:.*$/, '- Start date: 2026-10-01')
                   .sub(/^- Target date:.*$/, '- Target date: 2026-10-10')
                   .sub(/^- Status:.*$/, '- Status: not run')
                   .sub(/^- Reason:.*$/, '- Reason: Automation only.')
    metadata = PullRequestMetadata.parse(template, @contract)

    # The comment above the Related Issue placeholder documents `Closes #123`, so
    # a contributor who keeps the invisible comments must not have that issue
    # linked, labelled or reported as contradicting the `None` they left in place.
    assert_empty metadata['issues']
    assert_equal ['ci'], PullRequestMetadata.labels(metadata, @contract)
    assert_empty PullRequestMetadata.validate(title: 'ci: fill in the template', body: template, contract: @contract)
  end

  def test_repository_template_declares_every_required_section
    template = File.read(File.expand_path('../PULL_REQUEST_TEMPLATE.md', __dir__))
    sections = PullRequestMetadata.sections(template)

    PullRequestMetadata::REQUIRED_SECTIONS.each do |section|
      assert_includes sections.keys, section
    end
  end

  private

  def validate(title, **overrides)
    PullRequestMetadata.validate(title: title, body: build_body(**overrides), contract: @contract)
  end

  def parse(**overrides)
    PullRequestMetadata.parse(build_body(**overrides), @contract)
  end

  def build_body(type: 'ci', project: 'zshell Development', validation: nil, related: 'None', attribution: '- Agent: None',
                 schedule: "- Start date: 2026-10-01\n- Target date: 2026-10-10")
    <<~BODY
      ## Summary

      - Add pull request automation.

      ## GitHub Project

      - Project: #{project}
      #{schedule}

      ## PR Type

      - Type: #{type}

      ## Validation

      #{validation || "- Status: passed\n- Command: ruby .github/scripts/pr-metadata-test.rb\n- Result: 0 failures."}

      ## Risk and Rollback

      - Risk: Repository automation only.
      - Rollback: Revert this pull request.

      ## Related Issue

      #{related}

      ## AI Attribution

      #{attribution}
    BODY
  end
end
