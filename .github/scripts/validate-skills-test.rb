#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'tmpdir'

require_relative 'validate-skills'

class SkillValidatorTest < Minitest::Test
  def setup
    @temporary_directory = Pathname.new(Dir.mktmpdir('skill-validator-test'))
    @skills_directory = @temporary_directory / 'skills'
    @skills_directory.mkpath
  end

  def teardown
    FileUtils.remove_entry(@temporary_directory)
  end

  def test_accepts_canonical_frontmatter_and_local_reference
    skill_directory = write_skill(
      'valid-skill',
      <<~YAML,
        name: valid-skill
        description: Validates a complete skill fixture.
        license: MIT
        compatibility: Requires Ruby.
        metadata:
          author: test
          version: "1"
        allowed-tools: Read
      YAML
      '[Details](references/details.md#usage)'
    )
    reference = skill_directory / 'references/details.md'
    reference.dirname.mkpath
    reference.write("# Details\n")

    assert_validation true
  end

  def test_rejects_invalid_name_unknown_field_and_metadata_value
    write_skill(
      'bad--skill',
      <<~YAML,
        name: bad--skill
        description: Invalid fixture.
        unknown: value
        metadata:
          version: 1
      YAML
      '# Instructions'
    )

    assert_validation false
  end

  def test_rejects_missing_and_parent_references
    write_skill(
      'unsafe-skill',
      <<~YAML,
        name: unsafe-skill
        description: Contains invalid local references.
      YAML
      '[Missing](references/missing.md) [Parent](../outside.md)'
    )

    assert_validation false
  end

  def test_rejects_symlink_that_resolves_outside_skill_directory
    skill_directory = write_skill(
      'linked-skill',
      <<~YAML,
        name: linked-skill
        description: Contains an escaping symlink.
      YAML
      '[Outside](outside.md)'
    )
    outside = @temporary_directory / 'outside.md'
    outside.write("# Outside\n")
    File.symlink(outside, skill_directory / 'outside.md')

    assert_validation false
  end

  def test_accepts_unprefixed_release_download_urls
    write_skill(
      'flat-tag-skill',
      <<~YAML,
        name: flat-tag-skill
        description: References release assets through unprefixed tags.
      YAML
      <<~MARKDOWN
        - https://github.com/wzz6423/zshell/releases/download/v0.1.0/zshell-0.1.0.dmg
        - https://github.com/wzz6423/zshell/releases/download/updates/appcast.xml
        - https://github.com/wzz6423/zshell/releases/download/v${VERSION}/
        - https://github.com/wzz6423/zshell/releases/latest/download/appcast.xml
      MARKDOWN
    )

    assert_validation true
  end

  def test_rejects_path_prefixed_release_download_urls
    write_skill(
      'prefixed-tag-skill',
      <<~YAML,
        name: prefixed-tag-skill
        description: References release assets through a path-prefixed tag.
      YAML
      <<~MARKDOWN
        - https://github.com/wzz6423/zshell/releases/download/release/v0.1.0/zshell-0.1.0.dmg
        - https://gitee.com/wzz6423/zshell/releases/download/release/v0.1.0/zshell-0.1.0.dmg
      MARKDOWN
    )

    assert_validation false
  end

  # A message has to locate the file from the repository root: with more than one skill
  # root, a path relative to its own root does not say which tree the file came from.
  def test_errors_are_reported_relative_to_the_given_root
    write_skill(
      'mismatched-skill',
      <<~YAML,
        name: another-name
        description: The name does not match the directory.
      YAML
      '# Instructions'
    )

    _output, errors = capture_io do
      SkillValidator.new(@skills_directory, relative_to: @temporary_directory).run
    end

    assert_includes errors, 'skills/mismatched-skill/SKILL.md:'
  end

  # A skill tree that is moved or renamed would otherwise drop out of validation silently.
  def test_every_declared_root_holds_skills
    repository_root = Pathname.new(__dir__).join('../..').expand_path

    SKILL_ROOTS.each do |root|
      directory = repository_root / root
      assert_predicate directory, :directory?, "#{root} is not a directory"
      refute_empty directory.children.select(&:directory?), "#{root} holds no skill directories"
    end
  end

  private

  def write_skill(name, frontmatter, body)
    directory = @skills_directory / name
    directory.mkpath
    (directory / 'SKILL.md').write("---\n#{frontmatter}---\n\n#{body}\n")
    directory
  end

  def assert_validation(expected)
    result = nil
    _output, errors = capture_io { result = SkillValidator.new(@skills_directory).run }
    assert_equal expected, result, errors
  end
end
