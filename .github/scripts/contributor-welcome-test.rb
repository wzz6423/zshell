#!/usr/bin/env ruby
# frozen_string_literal: true

require 'minitest/autorun'
require 'yaml'
require 'json'
require 'open3'
require 'tmpdir'
require 'fileutils'

require_relative 'pr-metadata'

class ContributorWelcomeTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  MARKER = '<!-- zshell-contributor-welcome -->'

  def setup
    @directory = Dir.mktmpdir('zshell-contributor-welcome-')
    FileUtils.mkdir_p(File.join(@directory, 'bin'))
    FileUtils.mkdir_p(File.join(@directory, 'runner'))
    File.write(File.join(@directory, 'pages.json'), JSON.generate([[]]))
    path = File.join(@directory, 'bin/gh')
    File.write(path, <<~'SCRIPT')
      #!/usr/bin/env ruby
      require 'json'
      input = ARGV.include?('--input') ? File.read(ARGV[ARGV.index('--input') + 1]) : nil
      File.open(ENV.fetch('CAPTURE'), 'a') { |file| file.puts JSON.generate(args: ARGV, input: input) }
      if (ARGV & %w[POST PATCH]).any?
        exit ENV.fetch('WRITE_EXIT', '0').to_i
      end
      exit ENV.fetch('READ_EXIT', '0').to_i unless ENV.fetch('READ_EXIT', '0') == '0'
      if ENV.key?('READ_OUTPUT')
        puts ENV.fetch('READ_OUTPUT')
        exit
      end
      pages = JSON.parse(File.read(ENV.fetch('PAGES')))
      pages = [pages.first] unless ARGV.include?('--paginate')
      puts JSON.generate(ARGV.include?('--slurp') ? pages : pages.first)
    SCRIPT
    File.chmod(0o755, path)
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def test_rendered_pr_guidance_includes_the_schedule_contract
    body = render('pr')
    assert_includes body, '- Start date: 2026-10-05'
    assert_includes body, '- Target date: 2026-10-12'
    assert_includes body, 'required `Start date` and `Target date`'
    assert_includes body, '`YYYY-MM-DD`'
    assert_includes body, 'Missing, blank, duplicate, or invalid dates fail `PR Quality`'
    assert_includes body, '`Submitted date` automatically uses the creation date in UTC+08:00'
    assert_includes body, '`End date` is filled automatically when the pull request is closed or merged and cleared when it reopens'
    assert body.start_with?(MARKER)
    refute_includes body, '## Skipping CI'
    assert_includes File.read(File.join(ROOT, 'CONTRIBUTING.zh-CN.md')), '- Start date: 2026-10-05'
    assert_includes File.read(File.join(ROOT, 'CONTRIBUTING.zh-CN.md')), '- Target date: 2026-10-12'
  end

  def test_welcome_and_translated_guide_provide_valid_complete_pr_examples
    contract = PullRequestMetadata::Contract.load(File.join(ROOT, '.github/pr-automation.json'))
    examples = [
      [render('pr'), /Example PR title: `([^`]+)`/],
      [File.read(File.join(ROOT, 'CONTRIBUTING.zh-CN.md')), /示例 PR 标题：`([^`]+)`/]
    ]
    examples.each do |guidance, title_pattern|
      title = guidance.match(title_pattern)
      body = guidance.match(/  ```markdown\n(.*?)\n  ```/m)
      refute_nil title, 'The complete example must include a PR title.'
      refute_nil body, 'The complete example must include a copyable PR body.'
      example = body[1].gsub(/^  /, '')
      metadata = PullRequestMetadata.parse(example, contract)

      assert_equal PullRequestMetadata::REQUIRED_SECTIONS, metadata['sections'].keys
      assert_equal '2026-10-05', metadata['startDate']
      assert_equal '2026-10-12', metadata['targetDate']
      assert_equal metadata['type'], title[1].split(':', 2).first
      assert_empty PullRequestMetadata.validate(title: title[1], body: example, contract: contract)
    end
  end

  def test_first_run_posts_the_rendered_message
    output, status = run_workflow
    assert status.success?, output
    assert_equal 1, writes.size
    assert_includes writes.first.fetch('args'), 'POST'
    assert_includes writes.first.fetch('args'), 'repos/fixture/repository/issues/153/comments'
    assert_equal render('pr').rstrip, JSON.parse(writes.first.fetch('input')).fetch('body')
    assert_cleaned
  end

  def test_existing_bot_message_is_updated_in_place
    install_pages([[comment(42, "#{MARKER}\nOld guidance")]])
    output, status = run_workflow
    assert status.success?, output
    assert_equal 1, writes.size
    assert_includes writes.first.fetch('args'), 'PATCH'
    assert_includes writes.first.fetch('args'), 'repos/fixture/repository/issues/comments/42'
    assert_equal render('pr').rstrip, JSON.parse(writes.first.fetch('input')).fetch('body')
    assert_cleaned
  end

  def test_unchanged_message_does_not_write
    install_pages([[comment(42, render('pr').rstrip)]])
    output, status = run_workflow
    assert status.success?, output
    assert_empty writes
    assert_equal 1, calls.size
    assert_cleaned
  end

  def test_matching_message_on_a_later_page_is_updated
    install_pages([[comment(11, 'Unrelated reply')], [comment(42, MARKER)]])
    output, status = run_workflow
    assert status.success?, output
    assert_equal 1, writes.size
    assert_includes writes.first.fetch('args'), 'repos/fixture/repository/issues/comments/42'
    assert_cleaned
  end

  def test_human_and_other_bot_markers_and_unrelated_bot_messages_are_preserved
    install_pages([[
      comment(11, MARKER, 'contributor'), comment(12, MARKER, 'other[bot]'),
      comment(13, 'Unrelated reply'), comment(14, nil), comment(15, "Quoted guidance: #{MARKER}"),
      comment(16, " #{MARKER}"), comment(17, '<!-- other-contributor-welcome -->')
    ]])
    output, status = run_workflow
    assert status.success?, output
    assert_equal 1, writes.size
    assert_includes writes.first.fetch('args'), 'POST'
    assert_cleaned
  end

  def test_issue_refresh_uses_issue_guidance
    install_pages([[comment(42, MARKER)]])
    output, status = run_workflow('CONTRIBUTION_KIND' => 'issue', 'CONTRIBUTION_NUMBER' => '25')
    assert status.success?, output
    body = JSON.parse(writes.first.fetch('input')).fetch('body')
    assert_equal render('issue').rstrip, body
    refute_includes body, '## PR Type'
    assert_includes body, 'single **Timeline** comment'
    assert_includes body, 'UTC+08:00'
    assert_includes body, 'reopening clears `End date`'
    assert_includes calls.first.fetch('args'), 'repos/fixture/repository/issues/25/comments?per_page=100'
    assert_cleaned
  end

  def test_invalid_number_is_rejected_before_any_api_call
    ['', '0', '-1', '1.5', '1/../../pulls', '1;echo invalid', "1\n2"].each do |number|
      output, status = run_workflow('CONTRIBUTION_NUMBER' => number)
      refute status.success?, number.inspect
      assert_includes output, 'positive integer'
      assert_empty calls
      assert_cleaned
    end
  end

  def test_invalid_kind_is_rejected_before_any_api_call
    output, status = run_workflow('CONTRIBUTION_KIND' => 'discussion')
    refute status.success?
    assert_includes output, '<issue|pr>'
    assert_empty calls
    assert_cleaned
  end

  def test_comment_read_failure_never_writes
    _output, status = run_workflow('READ_EXIT' => '7')
    assert_equal 7, status.exitstatus
    assert_empty writes
    assert_cleaned
  end

  def test_malformed_comment_response_never_writes
    _output, status = run_workflow('READ_OUTPUT' => 'invalid JSON')
    refute status.success?
    assert_empty writes
    assert_cleaned
  end

  def test_post_and_patch_failures_propagate
    [[], [comment(42, MARKER)]].each do |comments|
      install_pages([comments])
      _output, status = run_workflow('WRITE_EXIT' => '9')
      assert_equal 9, status.exitstatus
      assert_cleaned
    end
  end

  def test_workflow_refresh_triggers_and_trust_boundary
    triggers = workflow.fetch(true)
    assert_equal %w[opened edited reopened closed], triggers.fetch('issues').fetch('types')
    assert_equal %w[opened edited synchronize reopened closed], triggers.fetch('pull_request_target').fetch('types')
    inputs = triggers.fetch('workflow_dispatch').fetch('inputs')
    assert_equal 'choice', inputs.fetch('kind').fetch('type')
    assert_equal %w[issue pr], inputs.fetch('kind').fetch('options')
    assert_equal 'string', inputs.fetch('number').fetch('type')
    assert inputs.fetch('number').fetch('required')
    job = workflow.fetch('jobs').fetch('welcome')
    assert_equal "${{ !endsWith(github.actor, '[bot]') }}", job.fetch('if')
    assert_equal '${{ github.event.repository.default_branch }}', steps.first.fetch('with').fetch('ref')
    assert_equal false, steps.first.fetch('with').fetch('persist-credentials')
    assert_equal({ 'contents' => 'read', 'issues' => 'write', 'pull-requests' => 'write' }, job.fetch('permissions'))
    assert_includes job.fetch('env').fetch('CONTRIBUTION_KIND'), 'inputs.kind'
    assert_includes job.fetch('env').fetch('CONTRIBUTION_NUMBER'), 'inputs.number'
    assert_equal false, workflow.fetch('concurrency').fetch('cancel-in-progress')
    assert_includes workflow.fetch('concurrency').fetch('group'), 'inputs.kind'
    assert_includes workflow.fetch('concurrency').fetch('group'), 'inputs.number'
    assert_equal 'always()', steps.last.fetch('if')
    steps.select { |step| step['run'] }.each { |step| refute_includes step.fetch('run'), '${{' }
    ci = YAML.load_file(File.join(ROOT, '.github/workflows/ci-lint.yml'))
    assert ci.fetch('jobs').fetch('scripts').fetch('steps').any? { |step| step['run'] == 'ruby .github/scripts/contributor-welcome-test.rb' }
  end

  private

  def workflow
    YAML.load_file(File.join(ROOT, '.github/workflows/contributor-welcome.yml'))
  end

  def steps
    workflow.fetch('jobs').fetch('welcome').fetch('steps')
  end

  def render(kind)
    output, status = Open3.capture2e({ 'GITHUB_REPOSITORY' => 'fixture/repository', 'GITHUB_SERVER_URL' => 'https://github.com',
                                      'GITHUB_DEFAULT_BRANCH' => 'main' },
                                    'bash', '.github/scripts/render-contributor-welcome.sh', kind, chdir: ROOT)
    assert status.success?, output
    output
  end

  def comment(id, body, author = 'github-actions[bot]')
    { id: id, body: body, user: { login: author } }
  end

  def install_pages(pages)
    File.write(File.join(@directory, 'pages.json'), JSON.generate(pages))
  end

  def run_workflow(env = {})
    result = nil
    steps.select { |step| step['run'] && step['if'] != 'always()' }.each do |step|
      result = run_step(step, env)
      break unless result.last.success?
    end
    result
  ensure
    steps.select { |step| step['if'] == 'always()' }.each do |step|
      output, status = run_step(step, env)
      assert status.success?, output
    end
  end

  def run_step(step, env)
    Open3.capture2e({
      'PATH' => "#{@directory}/bin:#{ENV.fetch('PATH')}",
      'CAPTURE' => File.join(@directory, 'calls.jsonl'),
      'PAGES' => File.join(@directory, 'pages.json'),
      'RUNNER_TEMP' => File.join(@directory, 'runner'),
      'GITHUB_REPOSITORY' => 'fixture/repository',
      'GITHUB_SERVER_URL' => 'https://github.com',
      'GITHUB_DEFAULT_BRANCH' => 'main',
      'CONTRIBUTION_KIND' => 'pr', 'CONTRIBUTION_NUMBER' => '153', 'GH_TOKEN' => 'fixture-token'
    }.merge(env), 'bash', '--noprofile', '--norc', '-e', '-c', step.fetch('run'), chdir: ROOT)
  end

  def calls
    path = File.join(@directory, 'calls.jsonl')
    File.exist?(path) ? File.readlines(path).map { |line| JSON.parse(line) } : []
  end

  def writes
    calls.select { |call| (call.fetch('args') & %w[POST PATCH]).any? }
  end

  def assert_cleaned
    assert_empty Dir.children(File.join(@directory, 'runner'))
  end
end
