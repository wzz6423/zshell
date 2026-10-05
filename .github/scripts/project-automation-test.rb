#!/usr/bin/env ruby
# frozen_string_literal: true

require 'minitest/autorun'
require 'yaml'
require 'json'
require 'open3'
require 'tmpdir'
require 'fileutils'

# Execute the checked-in workflow shell with a fake gh, including failures.
class ProjectAutomationTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)

  def setup
    @directory = Dir.mktmpdir('zshell-project-automation-')
    FileUtils.mkdir_p(File.join(@directory, 'bin'))
    FileUtils.mkdir_p(File.join(@directory, '.github'))
    File.write(File.join(@directory, 'comments.json'), '[]')
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def test_project_workflow_writes_dates_for_open_closed_merge_and_reopen
    install_workflow_fixture
    install_project_fields
    cases = [
      [workflow_event('issue', 'open'), '2026-10-04', nil],
      [workflow_event('issue', 'closed', closed_at: '2026-10-05T02:30:00Z'), '2026-10-04', '2026-10-05'],
      [workflow_event('pull_request', 'closed', closed_at: '2026-10-05T02:29:59Z',
        merged_at: '2026-10-05T02:30:00Z'), '2026-10-04', '2026-10-05'],
      [workflow_event('issue', 'open'), '2026-10-04', nil]
    ]

    cases.each do |event, submitted, ended|
      install_event(event)
      File.write(File.join(@directory, 'calls.jsonl'), '')
      output, status = run_project_step
      assert status.success?, output
      updates = graphql_calls('updateProjectV2ItemFieldValue')
      assert updates.any? { |call| call['args'].include?("date=#{submitted}") && call['args'].include?('fieldId=submitted-id') }
      if ended
        assert updates.any? { |call| call['args'].include?("date=#{ended}") && call['args'].include?('fieldId=ended-id') }
        assert_empty graphql_calls('clearProjectV2ItemFieldValue')
      else
        assert graphql_calls('clearProjectV2ItemFieldValue').any? { |call| call['args'].include?('fieldId=ended-id') }
      end
    end
  end

  def test_project_workflow_uses_current_state_when_an_old_event_is_replayed
    install_workflow_fixture
    install_project_fields
    %w[issue pull_request].product(%w[open closed]).each do |kind, state|
      old_state = state == 'open' ? 'closed' : 'open'
      event = workflow_event(kind, old_state, closed_at: '2026-10-05T02:30:00Z')
      current = workflow_event(kind, state, closed_at: '2026-10-06T02:30:00Z').fetch(kind)
      install_event(event, current_resource: current)
      File.write(File.join(@directory, 'calls.jsonl'), '')

      output, status = run_project_step
      assert status.success?, output
      updates = graphql_calls('updateProjectV2ItemFieldValue')
      if state == 'closed'
        assert updates.any? { |call| call['args'].include?('date=2026-10-06') && call['args'].include?('fieldId=ended-id') }
        assert updates.any? { |call| call['args'].include?('optionId=done-id') }
      else
        refute updates.any? { |call| call['args'].include?('fieldId=ended-id') }
        assert graphql_calls('clearProjectV2ItemFieldValue').any? { |call| call['args'].include?('fieldId=ended-id') }
      end
    end
  end

  def test_project_workflow_synchronizes_pull_request_schedule_from_the_current_body
    install_workflow_fixture
    install_project_fields
    event = workflow_event('pull_request', 'open')
    event['pull_request']['body'] = "## GitHub Project\n- Start date: 2026-10-01\n- Target date: 2026-10-10\n"
    current = event['pull_request'].merge('body' => "## GitHub Project\n- Start date: 2026-10-02\n- Target date: 2026-10-12\n")
    install_event(event, current_resource: current)

    output, status = run_project_step
    assert status.success?, output
    updates = graphql_calls('updateProjectV2ItemFieldValue')
    assert updates.any? { |call| call['args'].include?('fieldId=started-id') && call['args'].include?('date=2026-10-02') }
    assert updates.any? { |call| call['args'].include?('fieldId=target-id') && call['args'].include?('date=2026-10-12') }
    assert updates.any? { |call| call['args'].include?('fieldId=submitted-id') && call['args'].include?('date=2026-10-04') }
    assert_equal ['ended-id'], graphql_calls('clearProjectV2ItemFieldValue').map { |call| call['args'].find { |arg| arg.start_with?('fieldId=') }.delete_prefix('fieldId=') }
  end

  def test_project_workflow_creates_missing_schedule_fields_for_a_pull_request
    install_workflow_fixture
    install_project_fields([])
    event = workflow_event('pull_request', 'open')
    event['pull_request']['body'] = "## GitHub Project\n- Start date: 2026-10-01\n- Target date: 2026-10-10\n"
    install_event(event)

    output, status = run_project_step
    assert status.success?, output
    assert_equal ['End date', 'Start date', 'Submitted date', 'Target date'],
                 JSON.parse(File.read(File.join(@directory, 'fields.json'))).map { |field| field['name'] }.sort
    updates = graphql_calls('updateProjectV2ItemFieldValue')
    assert updates.any? { |call| call['args'].include?('fieldId=started-id') && call['args'].include?('date=2026-10-01') }
    assert updates.any? { |call| call['args'].include?('fieldId=target-id') && call['args'].include?('date=2026-10-10') }
  end

  def test_invalid_pull_request_schedule_cannot_mutate_the_project
    install_workflow_fixture
    install_project_fields
    event = workflow_event('pull_request', 'open')
    event['pull_request']['body'] = "## GitHub Project\n- Target date: 2026-02-30\n"
    install_event(event)

    output, status = run_project_step
    refute status.success?
    assert_includes output, 'Target date'
    assert_empty calls.select { |call| call['args'].include?('graphql') }
  end

  def test_blank_or_removed_schedule_preserves_project_values
    install_workflow_fixture
    bodies = ['', "## GitHub Project\n- Start date: <!-- YYYY-MM-DD -->\n- Target date: \n"]
    bodies.each do |body|
      install_project_fields
      event = workflow_event('pull_request', 'open')
      event['pull_request']['body'] = body
      install_event(event)
      File.write(File.join(@directory, 'calls.jsonl'), '')

      output, status = run_project_step
      assert status.success?, output
      mutations = graphql_calls('updateProjectV2ItemFieldValue') + graphql_calls('clearProjectV2ItemFieldValue')
      refute mutations.any? { |call| (call['args'] & %w[fieldId=started-id fieldId=target-id]).any? }
      assert_empty graphql_calls('createProjectV2Field')
    end
  end

  def test_each_schedule_date_can_be_supplied_independently
    install_workflow_fixture
    { 'Start date' => 'started-id', 'Target date' => 'target-id' }.each do |name, field_id|
      install_project_fields
      event = workflow_event('pull_request', 'open')
      event['pull_request']['body'] = "## GitHub Project\n- #{name}: 2026-10-10\n"
      install_event(event)
      File.write(File.join(@directory, 'calls.jsonl'), '')

      output, status = run_project_step
      assert status.success?, output
      updates = graphql_calls('updateProjectV2ItemFieldValue')
      assert updates.any? { |call| call['args'].include?("fieldId=#{field_id}") && call['args'].include?('date=2026-10-10') }
      other_id = field_id == 'started-id' ? 'target-id' : 'started-id'
      mutations = updates + graphql_calls('clearProjectV2ItemFieldValue')
      refute mutations.any? { |call| call['args'].include?("fieldId=#{other_id}") }
    end
  end

  def test_schedule_is_preserved_across_merge_and_reopen
    install_workflow_fixture
    install_project_fields
    %w[closed open].each do |state|
      event = workflow_event('pull_request', state, merged_at: '2026-10-05T02:30:00Z')
      event['pull_request']['body'] = "## GitHub Project\n- Start date: 2026-10-01\n- Target date: 2026-10-10\n"
      install_event(event)
      File.write(File.join(@directory, 'calls.jsonl'), '')

      output, status = run_project_step
      assert status.success?, output
      updates = graphql_calls('updateProjectV2ItemFieldValue')
      assert updates.any? { |call| call['args'].include?('fieldId=started-id') && call['args'].include?('date=2026-10-01') }
      assert updates.any? { |call| call['args'].include?('fieldId=target-id') && call['args'].include?('date=2026-10-10') }
      if state == 'closed'
        assert updates.any? { |call| call['args'].include?('fieldId=ended-id') && call['args'].include?('date=2026-10-05') }
        assert_empty graphql_calls('clearProjectV2ItemFieldValue')
      else
        assert_equal 1, graphql_calls('clearProjectV2ItemFieldValue').size
        assert graphql_calls('clearProjectV2ItemFieldValue').first['args'].include?('fieldId=ended-id')
      end
    end
  end

  def test_project_workflow_uses_current_merge_day_and_preserves_schedule
    install_workflow_fixture
    install_project_fields
    event = workflow_event('pull_request', 'closed',
      closed_at: '2026-10-04T02:29:59Z', merged_at: '2026-10-04T02:30:00Z')
    current = workflow_event('pull_request', 'closed',
      closed_at: '2026-10-05T15:59:59Z', merged_at: '2026-10-05T16:30:00Z').fetch('pull_request')
    current['body'] = "## GitHub Project\n- Start date: 2026-10-01\n- Target date: 2026-10-10\n"
    install_event(event, current_resource: current)

    output, status = run_project_step
    assert status.success?, output
    dates = graphql_calls('updateProjectV2ItemFieldValue').filter_map do |call|
      date = call['args'].find { |arg| arg.start_with?('date=') }
      [call['args'].find { |arg| arg.start_with?('fieldId=') }, date] if date
    end.to_h
    assert_equal({ 'fieldId=submitted-id' => 'date=2026-10-04',
                   'fieldId=ended-id' => 'date=2026-10-06',
                   'fieldId=started-id' => 'date=2026-10-01',
                   'fieldId=target-id' => 'date=2026-10-10' }, dates)
    assert_empty graphql_calls('clearProjectV2ItemFieldValue')
  end

  def test_wrong_schedule_field_type_fails_before_item_mutations
    install_workflow_fixture
    %w[Start Target].each do |name|
      install_project_fields([{ 'id' => 'wrong-id', 'name' => "#{name} date", 'dataType' => 'TEXT' }])
      event = workflow_event('pull_request', 'open')
      event['pull_request']['body'] = "## GitHub Project\n- #{name} date: 2026-10-10\n"
      install_event(event)
      File.write(File.join(@directory, 'calls.jsonl'), '')

      output, status = run_project_step
      refute status.success?
      assert_includes output, 'not a DATE field'
      assert_empty graphql_calls('updateProjectV2ItemFieldValue')
    end
  end

  def test_project_resource_read_failure_cannot_mutate_the_project
    install_workflow_fixture
    install_project_fields
    install_event(workflow_event('issue', 'open'))

    _output, status = run_project_step('GH_READ_EXIT' => '7')
    assert_equal 7, status.exitstatus
    assert_empty calls.select { |call| call['args'].include?('graphql') }
  end

  def test_project_workflow_creates_missing_date_fields
    install_workflow_fixture
    install_project_fields([])
    install_event(workflow_event('issue', 'open'))

    output, status = run_project_step
    assert status.success?, output
    assert_equal 2, graphql_calls('createProjectV2Field').length
    assert_equal %w[End\ date Submitted\ date],
                 JSON.parse(File.read(File.join(@directory, 'fields.json'))).map { |field| field['name'] }.sort
  end

  def test_project_workflow_accepts_a_concurrent_field_creation
    install_workflow_fixture
    install_project_fields([])
    install_event(workflow_event('issue', 'open'))

    output, status = run_project_step('CREATE_MODE' => 'race')
    assert status.success?, output
    assert_equal 2, graphql_calls('createProjectV2Field').length
  end

  def test_project_workflow_rejects_wrong_field_type_before_item_mutations
    install_workflow_fixture
    install_project_fields([{ 'id' => 'wrong-id', 'name' => 'Submitted date', 'dataType' => 'TEXT' }])
    install_event(workflow_event('issue', 'open'))

    output, status = run_project_step
    refute status.success?
    assert_includes output, 'not a DATE field'
    assert_empty graphql_calls('updateProjectV2ItemFieldValue')
  end

  def test_project_workflow_propagates_field_creation_permission_failure
    install_workflow_fixture
    install_project_fields([])
    install_event(workflow_event('issue', 'open'))

    output, status = run_project_step('CREATE_MODE' => 'permission')
    refute status.success?
    assert_includes output, 'Could not create the DATE field'
    assert_empty graphql_calls('updateProjectV2ItemFieldValue')
  end

  def test_project_workflow_propagates_date_graphql_error
    install_workflow_fixture
    install_project_fields
    install_event(workflow_event('issue', 'closed', closed_at: '2026-10-05T02:30:00Z'))

    output, status = run_project_step('GH_MUTATION_ERROR' => 'date')
    refute status.success?
    assert_includes output, 'date mutation rejected'
  end

  def test_project_workflow_stops_on_project_query_graphql_error
    install_workflow_fixture
    install_project_fields
    install_event(workflow_event('issue', 'open'))

    output, status = run_project_step('GH_READ_ERROR' => '1')
    refute status.success?
    assert_includes output, 'project query rejected'
    assert_empty graphql_calls('updateProjectV2ItemFieldValue')
  end

  def test_project_workflow_stops_on_field_creation_graphql_error
    install_workflow_fixture
    install_project_fields([])
    install_event(workflow_event('issue', 'open'))

    output, status = run_project_step('CREATE_MODE' => 'graphql_error')
    refute status.success?
    assert_includes output, 'Could not create the DATE field'
    assert_empty graphql_calls('updateProjectV2ItemFieldValue')
  end

  def test_latest_declared_type_still_wins_over_stale_labels
    install_workflow_fixture
    install_project_fields
    old = workflow_event('pull_request', 'open')
    current = old.fetch('pull_request').merge('body' => "## PR Type\n- Type: docs\n",
                                             'labels' => [{ 'name' => 'bug' }])
    install_event(old, current_resource: current)

    output, status = run_project_step
    assert status.success?, output
    assert graphql_calls('updateProjectV2ItemFieldValue').any? { |call| call['args'].include?('optionId=docs-id') }
  end

  def test_duplicate_or_malformed_schedule_cannot_mutate_the_project
    install_workflow_fixture
    install_project_fields
    ["- Start date:\n- Start date:", "- Target date: 2026-10-05; echo unsafe"].each do |schedule|
      event = workflow_event('pull_request', 'open')
      event['pull_request']['body'] = "## GitHub Project\n#{schedule}\n"
      install_event(event)
      File.write(File.join(@directory, 'calls.jsonl'), '')

      output, status = run_project_step
      refute status.success?, output
      assert_empty calls.select { |call| call['args'].include?('graphql') }
    end
  end

  def test_requery_http_failure_after_field_creation_cannot_write_items
    install_workflow_fixture
    install_event(workflow_event('issue', 'open'))
    %w[valid empty].each do |response|
      install_project_fields([])
      File.write(File.join(@directory, 'calls.jsonl'), '')

      _output, status = run_project_step('GH_PROJECT_READ_AFTER_CREATE_EXIT' => '7', 'GH_PROJECT_READ_RESPONSE' => response)
      assert_equal 7, status.exitstatus
      assert_equal 1, graphql_calls('createProjectV2Field').length
      assert_empty graphql_calls('updateProjectV2ItemFieldValue')
    end
  end

  def test_status_and_clear_graphql_errors_propagate
    install_workflow_fixture
    install_project_fields
    install_event(workflow_event('issue', 'open'))
    %w[status clear].each do |mutation|
      output, status = run_project_step('GH_MUTATION_ERROR' => mutation)
      refute status.success?
      assert_includes output, "#{mutation} mutation rejected"
    end
  end

  def test_mutation_http_failure_propagates
    install_workflow_fixture
    install_project_fields
    install_event(workflow_event('issue', 'open'))

    _output, status = run_project_step('GH_MUTATION_EXIT' => '7')
    assert_equal 7, status.exitstatus
  end

  def test_item_query_graphql_error_prevents_mutation
    install_workflow_fixture
    install_project_fields
    install_event(workflow_event('issue', 'open'))

    output, status = run_project_step('GH_ITEM_READ_ERROR' => '1')
    refute status.success?
    assert_includes output, 'item query rejected'
    assert_empty graphql_calls('updateProjectV2ItemFieldValue')
    assert_empty graphql_calls('addProjectV2ItemById')
  end

  def test_missing_project_token_skips_project_calls
    install_workflow_fixture
    install_event(workflow_event('issue', 'open'))

    output, status = run_project_step('PROJECT_TOKEN' => '')
    assert status.success?, output
    assert_includes output, 'project synchronization is skipped'
    assert_empty calls
  end

  def test_timeline_updates_one_bot_comment_and_uses_current_close_and_reopen_state
    install_workflow_fixture
    human = { 'id' => 1, 'body' => '<!-- zshell-item-timeline --> Human text', 'user' => { 'login' => 'human' } }
    File.write(File.join(@directory, 'comments.json'), JSON.generate([human]))
    event = workflow_event('issue', 'open')
    current = workflow_event('issue', 'closed', closed_at: '2026-10-05T16:30:00Z').fetch('issue')
    install_event(event, current_resource: current)

    output, status = run_timeline_step
    assert status.success?, output
    comments = JSON.parse(File.read(File.join(@directory, 'comments.json')))
    assert_equal 2, comments.length
    assert_equal human, comments.first
    assert_includes comments.last['body'], '- Completed: `2026-10-06 00:30:00 UTC+08:00` (closed)'

    output, status = run_timeline_step
    assert status.success?, output
    assert_includes output, 'already up to date'
    assert_equal 1, calls.count { |call| (call['args'] & %w[POST PATCH]).any? }

    install_event({ 'issue' => current }, current_resource: current.merge('state' => 'open'))
    output, status = run_timeline_step
    assert status.success?, output
    comments = JSON.parse(File.read(File.join(@directory, 'comments.json')))
    assert_equal [1, 42], comments.map { |comment| comment['id'] }
    assert_includes comments.last['body'], '- Completed: Pending'
    assert_equal 1, calls.count { |call| call['args'].include?('PATCH') }
  end

  def test_timeline_uses_current_merge_time_and_does_not_edit_the_pr_body
    install_workflow_fixture
    old = workflow_event('pull_request', 'open')
    current = workflow_event('pull_request', 'closed', closed_at: '2026-10-05T15:59:59Z',
                             merged_at: '2026-10-05T16:30:00Z').fetch('pull_request')
    current['body'] = 'Contributor-owned description'
    install_event(old, current_resource: current)

    output, status = run_timeline_step
    assert status.success?, output
    comment = JSON.parse(File.read(File.join(@directory, 'comments.json'))).last
    assert_includes comment['body'], '- Submitted: `2026-10-04 00:30:00 UTC+08:00`'
    assert_includes comment['body'], '- Completed: `2026-10-06 00:30:00 UTC+08:00` (merged)'
    assert_equal current, JSON.parse(File.read(File.join(@directory, 'resource.json')))
    assert calls.any? { |call| call['args'].include?('repos/fixture/repository/pulls/153') }
  end

  def test_timeline_api_failures_propagate_without_writing_a_comment
    install_workflow_fixture
    install_event(workflow_event('issue', 'open'))
    %w[GH_READ_EXIT GH_COMMENTS_READ_EXIT GH_TIMELINE_WRITE_EXIT].each do |key|
      _output, status = run_timeline_step(key => '7')
      assert_equal 7, status.exitstatus
      assert_equal [], JSON.parse(File.read(File.join(@directory, 'comments.json')))
    end
  end

  def test_cleanup_removes_all_workflow_payloads
    install_workflow_fixture
    install_project_fields([])
    install_event(workflow_event('issue', 'open'))
    output, status = run_timeline_step
    assert status.success?, output
    output, status = run_project_step
    assert status.success?, output

    output, status = run_step(step('project-automation', 'Remove project payloads'))
    assert status.success?, output
    assert_empty Dir.glob(File.join(@directory, 'project-*'))
    assert_empty Dir.glob(File.join(@directory, 'item-timeline*'))
  end

  private

  def install_workflow_fixture
    FileUtils.mkdir_p(File.join(@directory, '.github/scripts'))
    %w[project-dates.rb project-status.rb pr-metadata.rb item-timeline.rb].each do |name|
      FileUtils.cp(File.join(ROOT, '.github/scripts', name), File.join(@directory, '.github/scripts', name))
    end
    FileUtils.cp(File.join(ROOT, '.github/project-automation.json'), File.join(@directory, '.github/project-automation.json'))
    FileUtils.cp(File.join(ROOT, '.github/pr-automation.json'), File.join(@directory, '.github/pr-automation.json'))
    File.write(File.join(@directory, 'bin/gh'), <<~'SCRIPT')
      #!/usr/bin/env ruby
      require 'json'
      input = ARGV.include?('--input') ? File.read(ARGV[ARGV.index('--input') + 1]) : nil
      File.open(ENV.fetch('CAPTURE'), 'a') { |file| file.puts JSON.generate(args: ARGV, input: input) }
      if ARGV.include?('graphql')
        query = ARGV.find { |arg| arg.start_with?('query=') }.to_s
        fields = JSON.parse(File.read(ENV.fetch('FIELD_STATE')))
        case query
        when /query\(\$login:/
          if ENV['GH_READ_ERROR'] == '1'
            puts JSON.generate(errors: [{ message: 'project query rejected' }])
            exit
          end
          if fields.any? && ENV['GH_PROJECT_READ_RESPONSE'] == 'empty'
            exit ENV.fetch('GH_PROJECT_READ_AFTER_CREATE_EXIT').to_i
          end
          status = { id: 'status-id', name: 'Status', dataType: 'SINGLE_SELECT', options: [
            { id: 'inbox-id', name: 'Inbox' }, { id: 'done-id', name: 'Done' },
            { id: 'bug-id', name: 'Bug Fix' }, { id: 'docs-id', name: 'Documentation' },
            { id: 'ci-id', name: 'CI & Build' }
          ] }
          puts JSON.generate(data: { user: { projectV2: {
            id: 'project-id', title: 'zshell Development', fields: { nodes: [status, *fields] }
          } } })
          exit ENV.fetch('GH_PROJECT_READ_AFTER_CREATE_EXIT', '0').to_i if fields.any?
        when /query\(\$projectId:/
          if ENV['GH_ITEM_READ_ERROR'] == '1'
            puts JSON.generate([{ errors: [{ message: 'item query rejected' }] }])
            exit
          end
          puts JSON.generate([{ data: { node: { items: { nodes: [
            { id: 'item-id', content: { id: 'content-id' } }
          ], pageInfo: { hasNextPage: false, endCursor: nil } } } } }])
        when /createProjectV2Field/
          mode = ENV.fetch('CREATE_MODE', 'success')
          if mode == 'graphql_error'
            puts JSON.generate(errors: [{ message: 'field creation rejected' }])
            exit
          end
          if mode == 'permission'
            warn 'permission denied'
            exit 7
          end
          name = ARGV.find { |arg| arg.start_with?('name=') }.delete_prefix('name=')
          ids = { 'Submitted date' => 'submitted-id', 'End date' => 'ended-id',
                  'Start date' => 'started-id', 'Target date' => 'target-id' }
          fields << { 'id' => ids.fetch(name),
                      'name' => name, 'dataType' => 'DATE' }
          File.write(ENV.fetch('FIELD_STATE'), JSON.generate(fields))
          if mode == 'race'
            warn 'field already exists'
            exit 7
          end
          puts JSON.generate(data: { createProjectV2Field: { projectV2Field: { id: fields.last['id'] } } })
        when /updateProjectV2ItemFieldValue/
          exit 7 if ENV['GH_MUTATION_EXIT'] == '7'
          if ENV['GH_MUTATION_ERROR'] == 'status' && ARGV.any? { |arg| arg.start_with?('optionId=') }
            puts JSON.generate(errors: [{ message: 'status mutation rejected' }])
          elsif ENV['GH_MUTATION_ERROR'] == 'date' && ARGV.any? { |arg| arg.start_with?('date=') }
            puts JSON.generate(errors: [{ message: 'date mutation rejected' }])
          else
            puts JSON.generate(data: { updateProjectV2ItemFieldValue: { projectV2Item: { id: 'item-id' } } })
          end
        when /clearProjectV2ItemFieldValue/
          if ENV['GH_MUTATION_ERROR'] == 'clear'
            puts JSON.generate(errors: [{ message: 'clear mutation rejected' }])
            exit
          end
          puts JSON.generate(data: { clearProjectV2ItemFieldValue: { projectV2Item: { id: 'item-id' } } })
        else
          warn "Unexpected GraphQL query: #{query}"
          exit 8
        end
      elsif ARGV.include?('PATCH') || ARGV.include?('POST')
        exit ENV.fetch('GH_TIMELINE_WRITE_EXIT', '0').to_i unless ENV.fetch('GH_TIMELINE_WRITE_EXIT', '0') == '0'
        comments = JSON.parse(File.read(ENV.fetch('COMMENTS_PATH')))
        payload = JSON.parse(input)
        if ARGV.include?('POST')
          comments << { 'id' => 42, 'body' => payload.fetch('body'), 'user' => { 'login' => 'github-actions[bot]' } }
        else
          id = ARGV.find { |arg| arg.start_with?('repos/') }.split('/').last.to_i
          comments.find { |comment| comment['id'] == id }.merge!(payload)
        end
        File.write(ENV.fetch('COMMENTS_PATH'), JSON.generate(comments))
        puts '{}'
      elsif ARGV.any? { |arg| arg.include?('/comments?') }
        exit ENV.fetch('GH_COMMENTS_READ_EXIT', '0').to_i unless ENV.fetch('GH_COMMENTS_READ_EXIT', '0') == '0'
        puts JSON.generate([JSON.parse(File.read(ENV.fetch('COMMENTS_PATH')))])
      else
        exit ENV.fetch('GH_READ_EXIT', '0').to_i unless ENV.fetch('GH_READ_EXIT', '0') == '0'
        puts File.read(ENV.fetch('RESOURCE_PATH'))
      end
    SCRIPT
    File.chmod(0o755, File.join(@directory, 'bin/gh'))
  end

  def install_project_fields(fields = [
    { 'id' => 'submitted-id', 'name' => 'Submitted date', 'dataType' => 'DATE' },
    { 'id' => 'ended-id', 'name' => 'End date', 'dataType' => 'DATE' },
    { 'id' => 'started-id', 'name' => 'Start date', 'dataType' => 'DATE' },
    { 'id' => 'target-id', 'name' => 'Target date', 'dataType' => 'DATE' }
  ])
    File.write(File.join(@directory, 'fields.json'), JSON.generate(fields))
  end

  def workflow_event(kind, state, closed_at: nil, merged_at: nil)
    { kind => { 'node_id' => 'content-id', 'number' => 153, 'body' => '', 'labels' => [],
                'state' => state, 'created_at' => '2026-10-03T16:30:00Z',
                'closed_at' => closed_at, 'merged_at' => merged_at } }
  end

  def install_event(event, current_resource: event.values.first)
    File.write(File.join(@directory, 'event.json'), JSON.generate(event))
    File.write(File.join(@directory, 'resource.json'), JSON.generate(current_resource))
  end

  def run_timeline_step(env = {})
    run_step(step('project-automation', 'Record item timeline'), {
      'GITHUB_EVENT_PATH' => File.join(@directory, 'event.json'),
      'RESOURCE_PATH' => File.join(@directory, 'resource.json'),
      'COMMENTS_PATH' => File.join(@directory, 'comments.json'),
      'ITEM_NUMBER' => '153', 'TIMELINE_MARKER' => '<!-- zshell-item-timeline -->'
    }.merge(env))
  end

  def run_project_step(env = {})
    run_step(step('project-automation', 'Add item and synchronize status'), {
      'GITHUB_EVENT_PATH' => File.join(@directory, 'event.json'),
      'RESOURCE_PATH' => File.join(@directory, 'resource.json'),
      'FIELD_STATE' => File.join(@directory, 'fields.json'),
      'PROJECT_TOKEN' => 'fixture-token'
    }.merge(env))
  end

  def graphql_calls(operation)
    calls.select do |call|
      call['args'].include?('graphql') && call['args'].any? { |arg| arg.start_with?('query=') && arg.include?(operation) }
    end
  end

  def step(workflow, name)
    YAML.load_file(File.join(ROOT, '.github/workflows', "#{workflow}.yml"))
        .fetch('jobs').values.flat_map { |job| job.fetch('steps') }.find { |entry| entry['name'] == name } || raise(name)
  end

  def run_step(step, env = {})
    Open3.capture2e({
      'PATH' => "#{@directory}/bin:#{ENV.fetch('PATH')}",
      'CAPTURE' => File.join(@directory, 'calls.jsonl'),
      'RUNNER_TEMP' => @directory,
      'GITHUB_REPOSITORY' => 'fixture/repository',
      'GH_TOKEN' => 'fixture-token',
      'ITEM_NUMBER' => '153'
    }.merge(env), 'bash', '-c', step.fetch('run'), chdir: @directory)
  end

  def calls
    path = File.join(@directory, 'calls.jsonl')
    File.exist?(path) ? File.readlines(path).map { |line| JSON.parse(line) } : []
  end

end
