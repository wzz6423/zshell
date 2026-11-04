#!/usr/bin/env ruby
# frozen_string_literal: true

require 'minitest/autorun'
require 'yaml'
require 'open3'
require_relative 'pr-metadata'

class CodeRabbitConfigTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)

  def setup
    @config = YAML.load_file(File.join(ROOT, '.coderabbit.yaml'))
    @template = File.read(File.join(ROOT, '.github/PULL_REQUEST_TEMPLATE.md'))
  end

  def test_drafts_and_every_push_receive_nonblocking_reviews
    reviews = @config.fetch('reviews')
    auto_review = reviews.fetch('auto_review')

    assert auto_review.fetch('enabled')
    assert auto_review.fetch('auto_incremental_review')
    assert auto_review.fetch('drafts')
    assert_equal 0, auto_review.fetch('auto_pause_after_reviewed_commits')
    refute reviews.fetch('request_changes_workflow')
    refute reviews.fetch('tools').fetch('github-checks').fetch('enabled')
  end

  def test_diagram_summary_targets_the_pull_request_description
    reviews = @config.fetch('reviews')
    placeholder = reviews.fetch('high_level_summary_placeholder', '@coderabbitai summary')
    summary = PullRequestMetadata.sections(@template).fetch('Summary').join("\n")

    assert reviews.fetch('high_level_summary')
    refute reviews.fetch('high_level_summary_in_walkthrough')
    assert_includes reviews.fetch('high_level_summary_instructions'), '```mermaid'
    assert_includes summary, placeholder
    assert_equal 1, @template.scan(placeholder).length
  end

  def test_stacked_pull_requests_receive_reviews
    patterns = @config.fetch('reviews').fetch('auto_review').fetch('base_branches')

    ['feat/parent-change', 'ci/review-automation', 'publish-v1.0.0'].each do |branch|
      assert patterns.any? { |pattern| Regexp.new(pattern).match?(branch) }, branch
    end
  end

  def test_generated_diagram_preserves_the_existing_pull_request_contract
    output, status = Open3.capture2e('bash', '.github/scripts/render-contributor-welcome.sh', 'pr', chdir: ROOT)
    assert status.success?, output
    example = output[/^  ```markdown\n(.*?)^  ```/m, 1]
    refute_nil example
    body = example.lines.map { |line| line.sub(/^  /, '') }.join
    diagram = <<~MARKDOWN
      <!-- coderabbit-ai-generated:v1 -->
      ## Summary by CodeRabbit

      ### Change flow

      ```mermaid
      flowchart TD
        opened["PR opened or updated"] --> review["Review changed code"]
        review --> summary["Update PR summary and diagram"]
      ```
      <!-- end of auto-generated comment: release notes by coderabbit.ai -->
    MARKDOWN
    generated_body = body.sub("## Summary\n", "## Summary\n\n#{diagram}\n")
    contract = PullRequestMetadata::Contract.load(File.join(ROOT, '.github/pr-automation.json'))

    assert_empty PullRequestMetadata.validate(title: 'ci: add a repository hygiene check', body: generated_body, contract: contract)
    assert_equal PullRequestMetadata.parse(body, contract).except('sections'),
                 PullRequestMetadata.parse(generated_body, contract).except('sections')
  end
end
