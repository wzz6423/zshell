#!/usr/bin/env ruby
# frozen_string_literal: true

require 'minitest/autorun'

require_relative 'project-status'

class ProjectStatusTest < Minitest::Test
  PROJECT_CONTRACT_PATH = File.expand_path('../project-automation.json', __dir__)
  PR_CONTRACT_PATH = File.expand_path('../pr-automation.json', __dir__)

  def setup
    @project_contract = ProjectStatus::Contract.load(PROJECT_CONTRACT_PATH)
    @pr_contract = PullRequestMetadata::Contract.load(PR_CONTRACT_PATH)
  end

  def test_open_pull_request_uses_declared_type_before_labels_are_applied
    assert_equal 'Bug Fix', resolve(pull_request(type: 'fix'))
  end

  def test_edited_pull_request_type_wins_over_a_stale_event_label
    event = pull_request(type: 'docs', labels: ['bug'])

    assert_equal 'Documentation', resolve(event)
  end

  def test_open_issue_continues_to_use_event_labels
    event = issue(labels: ['area:ci-build', 'bug'])

    assert_equal 'CI & Build', resolve(event)
  end

  def test_event_labels_are_the_fallback_for_content_without_metadata
    assert_equal 'CI & Build', resolve(pull_request(type: nil, labels: ['ci']))
  end

  def test_unmapped_content_uses_the_default_status
    assert_equal 'Inbox', resolve(pull_request(type: nil, labels: ['dependencies']))
  end

  def test_closed_content_always_uses_the_closed_status
    assert_equal 'Done', resolve(pull_request(type: 'fix', state: 'closed'))
  end

  def test_rejects_an_event_without_supported_content
    error = assert_raises(ProjectStatus::ContractError) { resolve({ 'repository' => {} }) }

    assert_equal 'event contains no Issue or pull request', error.message
  end

  private

  def resolve(event)
    ProjectStatus.desired_status(
      event: event,
      project_contract: @project_contract,
      pr_contract: @pr_contract
    )
  end

  def pull_request(type:, labels: [], state: 'open')
    body = type ? "## PR Type\n\n- Type: #{type}\n" : ''
    {
      'pull_request' => {
        'body' => body,
        'labels' => labels.map { |label| { 'name' => label } },
        'state' => state
      }
    }
  end

  def issue(labels: [], state: 'open')
    {
      'issue' => {
        'labels' => labels.map { |label| { 'name' => label } },
        'state' => state
      }
    }
  end
end
