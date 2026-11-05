#!/usr/bin/env ruby
# frozen_string_literal: true

require 'minitest/autorun'
require 'yaml'
require 'json'

class CiLayoutTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)

  def test_only_skip_gates_use_sparse_checkouts
    manifest = JSON.parse(File.read(File.join(ROOT, '.github/ci-skip.json')))

    manifest.fetch('workflows').each do |entry|
      workflow_jobs(entry.fetch('file')).each do |id, job|
        checkout = job.fetch('steps', []).find { |step| step.fetch('uses', '').start_with?('actions/checkout@') }
        next unless checkout

        options = checkout.fetch('with')
        assert_equal false, options.fetch('persist-credentials'), entry.fetch('name')
        if id == 'gate'
          assert_equal '.github', options.fetch('sparse-checkout'), entry.fetch('name')
        else
          refute options.key?('sparse-checkout'), "#{entry.fetch('name')}/#{id} needs the full source tree"
        end
      end
    end
  end

  def test_workflow_lint_and_security_audit_still_run_after_script_failures
    steps = workflow_jobs('ci-lint.yml').fetch('scripts').fetch('steps')

    ['Run actionlint', 'Run zizmor'].each do |name|
      step = steps.find { |candidate| candidate['name'] == name }
      refute_nil step, name
      assert_equal '${{ !cancelled() }}', step.fetch('if'), name
      refute step.fetch('continue-on-error', false), name
    end
    audit = steps.find { |step| step['name'] == 'Run zizmor' }.fetch('with')
    assert_equal '.github/workflows', audit.fetch('inputs')
    assert_equal 'workflows', audit.fetch('collect')
    assert steps.any? { |step| step['run'] == 'ruby .github/scripts/ci-layout-test.rb' }
  end

  def test_release_shell_and_updater_checks_still_run_after_typescript_failures
    job = workflow_jobs('release-scripts.yml').fetch('typecheck')
    steps = job.fetch('steps')

    assert_equal 'macos-26', job.fetch('runs-on')
    ['Syntax check release and build scripts', 'Check the dev icon generator',
     'Test updater architecture and fallback behavior'].each do |name|
      step = steps.find { |candidate| candidate['name'] == name }
      refute_nil step, name
      assert_equal '${{ !cancelled() }}', step.fetch('if'), name
      refute step.fetch('continue-on-error', false), name
    end
    cleanup = steps.last
    assert_equal 'always()', cleanup.fetch('if')
    assert_includes cleanup.fetch('run'), 'mac/node_modules'
    assert_includes cleanup.fetch('run'), 'mac/scripts/__pycache__'
  end

  def test_remote_protocol_and_release_regressions_are_independent_on_both_platforms
    jobs = workflow_jobs('remote-sessions.yml')
    protocol = jobs.fetch('protocol')
    server = jobs.fetch('server')

    [protocol, server].each do |job|
      assert_equal 'gate', job.fetch('needs')
      assert_equal false, job.fetch('strategy').fetch('fail-fast')
      assert_equal %w[Linux macOS], job.fetch('strategy').fetch('matrix').fetch('include').map { |entry| entry.fetch('platform') }
      assert_equal 'always()', job.fetch('steps').last.fetch('if')
    end
    assert_equal protocol.fetch('if'), server.fetch('if')
    assert_equal protocol.fetch('strategy'), server.fetch('strategy')
    protocol_commands = protocol.fetch('steps').filter_map { |step| step['run'] }.join("\n")
    server_commands = server.fetch('steps').filter_map { |step| step['run'] }.join("\n")
    assert_includes protocol_commands, 'cargo test --locked --manifest-path remote/Cargo.toml'
    assert_includes server_commands, 'cargo build --locked --release --manifest-path remote/Cargo.toml'
    assert_includes server_commands, 'remote/tests/test_cli.py'
    assert_includes server_commands, '--require-other-uid'
    assert_includes server_commands, 'remote/tests/test_agents.py'
    assert_includes server_commands, 'remote/tests/test_shared_codex.py'
    refute_includes protocol_commands, 'cargo build --locked --release'
    refute_includes server_commands, 'cargo test'
  end

  def test_native_swift_analysis_preserves_the_query_suite_and_arm_app_build
    jobs = workflow_jobs('macos-app.yml')
    codeql = jobs.fetch('codeql')
    init = codeql.fetch('steps').find { |step| step.fetch('uses', '').start_with?('github/codeql-action/init@') }

    assert_equal 'macos-26-intel', codeql.fetch('runs-on')
    assert_equal 'macos-26', jobs.fetch('app-smoke').fetch('runs-on')
    assert_equal 'swift', init.fetch('with').fetch('languages')
    assert_equal 'manual', init.fetch('with').fetch('build-mode')
    assert_equal 'security-and-quality', init.fetch('with').fetch('queries')
    build = codeql.fetch('steps').find { |step| step['name'] == 'Build for analysis' }.fetch('run')
    assert_includes build, '-project mac/zshell.xcodeproj'
    assert_includes build, '-scheme zshell'
    assert_includes build, '-configuration Debug'
  end

  private

  def workflow_jobs(file)
    YAML.load_file(File.join(ROOT, '.github/workflows', file)).fetch('jobs')
  end
end
