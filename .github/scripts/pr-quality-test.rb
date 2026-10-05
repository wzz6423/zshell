#!/usr/bin/env ruby
# frozen_string_literal: true

require 'minitest/autorun'
require 'yaml'
require 'open3'
require 'tmpdir'
require 'fileutils'

class PullRequestQualityTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  TITLE = 'ci: add a repository hygiene check'

  def setup
    @directory = Dir.mktmpdir('zshell-pr-quality-')
    workflow = YAML.load_file(File.join(ROOT, '.github/workflows/pr-quality-gates.yml'))
    steps = workflow.fetch('jobs').fetch('validate').fetch('steps')
    @validate_step = steps.find { |step| step['name'] == 'Validate title and body' }.fetch('run')
    @cleanup_step = steps.find { |step| step['if'] == 'always()' }.fetch('run')
    output, status = Open3.capture2e('bash', '.github/scripts/render-contributor-welcome.sh', 'pr', chdir: ROOT)
    assert status.success?, output
    example = output[/^  ```markdown\n(.*?)^  ```/m, 1]
    refute_nil example, 'The welcome reply must include a complete PR body example.'
    @body = example.lines.map { |line| line.sub(/^  /, '') }.join
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def test_complete_welcome_example_passes_the_actual_quality_step
    output, status = validate(@body)

    assert status.success?, output
    assert_includes output, 'Pull request metadata is valid.'
  end

  def test_missing_schedule_fields_fail_the_actual_quality_step
    ['Start date', 'Target date'].each do |field|
      assert_rejected(@body.gsub(/^- #{field}:.*\n/, ''), field)
    end
    assert_rejected(@body.gsub(/^- (Start|Target) date:.*\n/, ''), 'Start date')
  end

  def test_empty_schedule_fields_and_template_comments_fail_the_actual_quality_step
    ['Start date', 'Target date'].product(['', '   ', '<!-- YYYY-MM-DD -->']).each do |field, value|
      assert_rejected(@body.sub(/^- #{field}:.*$/, "- #{field}: #{value}"), field)
    end
  end

  def test_invalid_schedule_dates_fail_the_actual_quality_step
    ['Start date', 'Target date'].product(['2026-02-30', '2026-2-01', 'tomorrow']).each do |field, value|
      assert_rejected(@body.sub(/^- #{field}:.*$/, "- #{field}: #{value}"), field)
    end
  end

  def test_duplicate_schedule_fields_fail_the_actual_quality_step
    ['Start date', 'Target date'].product(['', '2026-10-06']).each do |field, value|
      body = @body.sub(/(^- #{field}:.*$)/, "\\1\n- #{field}: #{value}")
      assert_rejected(body, field)
    end
  end

  def test_missing_project_section_fails_the_actual_quality_step
    assert_rejected(@body.sub(/## GitHub Project\n.*?(?=## PR Type)/m, ''), '## GitHub Project')
  end

  def test_ci_runs_the_quality_regressions
    ci = YAML.load_file(File.join(ROOT, '.github/workflows/ci-lint.yml'))
    assert ci.fetch('jobs').fetch('scripts').fetch('steps').any? { |step| step['run'] == 'ruby .github/scripts/pr-quality-test.rb' }
  end

  private

  def assert_rejected(body, field)
    output, status = validate(body)
    refute status.success?, "CI accepted invalid #{field}: #{output}"
    assert_includes output, field
  end

  def validate(body)
    env = { 'PR_TITLE' => TITLE, 'PR_BODY' => body, 'RUNNER_TEMP' => @directory }
    Open3.capture2e(env, 'bash', '--noprofile', '--norc', '-e', '-o', 'pipefail', '-c', @validate_step, chdir: ROOT)
  ensure
    output, status = Open3.capture2e(env, 'bash', '-e', '-c', @cleanup_step, chdir: ROOT)
    assert status.success?, output
    assert_empty Dir.children(@directory)
  end
end
