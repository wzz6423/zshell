#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'optparse'

require_relative 'pr-metadata'

# Resolves the project Status from the metadata that owns an Issue or pull
# request's routing, without waiting for a separate workflow to apply labels.
module ProjectStatus
  class ContractError < StandardError; end

  class Contract
    attr_reader :closed_status

    def self.load(path)
      new(JSON.parse(File.read(path)))
    rescue JSON::ParserError => error
      raise ContractError, "#{path}: invalid JSON (#{error.message})"
    end

    def initialize(document)
      @default_status = document.fetch('defaultStatus')
      @closed_status = document.fetch('closedStatus')
      @label_status = Array(document['labelStatus'])
      raise ContractError, 'contract declares no label status rules' if @label_status.empty?
    end

    def status_for(labels)
      names = Array(labels)
      rule = @label_status.find { |entry| names.include?(entry['label']) }
      rule ? rule.fetch('status') : @default_status
    end
  end

  def self.desired_status(event:, project_contract:, pr_contract: nil)
    content = event['pull_request'] || event['issue']
    raise ContractError, 'event contains no Issue or pull request' if content.nil?

    return project_contract.closed_status if content['state'] == 'closed'

    metadata_label = pull_request_label(content, pr_contract) if event['pull_request']
    project_contract.status_for(metadata_label ? [metadata_label] : event_labels(content))
  end

  def self.pull_request_label(pull_request, contract)
    return nil if contract.nil?

    PullRequestMetadata.parse(pull_request['body'], contract)['typeLabel']
  end

  def self.event_labels(content)
    Array(content['labels']).filter_map { |label| label['name'] }
  end
end

def command_resolve(options)
  event = JSON.parse(File.read(options.fetch(:event_file)))
  project_contract = ProjectStatus::Contract.load(options.fetch(:project_manifest))
  pr_contract = if event['pull_request']
                  PullRequestMetadata::Contract.load(options.fetch(:pr_manifest))
                end

  puts ProjectStatus.desired_status(
    event: event,
    project_contract: project_contract,
    pr_contract: pr_contract
  )
end

if $PROGRAM_NAME == __FILE__
  base = __dir__
  options = {
    project_manifest: File.expand_path('../project-automation.json', base),
    pr_manifest: File.expand_path('../pr-automation.json', base)
  }
  parser = OptionParser.new do |opts|
    opts.banner = 'Usage: project-status.rb resolve --event-file PATH'
    opts.on('--event-file PATH', 'GitHub event payload') { |value| options[:event_file] = value }
    opts.on('--project-manifest PATH', 'Project status contract') { |value| options[:project_manifest] = value }
    opts.on('--pr-manifest PATH', 'Pull request metadata contract') { |value| options[:pr_manifest] = value }
  end

  command = parser.parse(ARGV).shift
  begin
    raise OptionParser::InvalidArgument, parser.banner unless command == 'resolve'

    command_resolve(options)
  rescue ProjectStatus::ContractError, PullRequestMetadata::ContractError,
         KeyError, Errno::ENOENT, JSON::ParserError,
         OptionParser::ParseError, TypeError => error
    warn error.message
    exit 1
  end
end
