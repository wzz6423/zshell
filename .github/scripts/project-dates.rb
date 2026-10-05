#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'optparse'
require 'time'

require_relative 'pr-metadata'

# The board and Timeline comment share one lifecycle and timezone contract.
module ProjectDates
  TIME_ZONE_OFFSET = '+08:00'
  class ContractError < StandardError; end

  def self.timestamps_for(event)
    content = event['pull_request'] || event['issue']
    raise ContractError, 'event contains no Issue or pull request' unless content.is_a?(Hash)

    created_at = content['created_at'] || content['createdAt']
    raise ContractError, 'content has no created timestamp' if created_at.to_s.empty?

    merged_at = event.key?('pull_request') && (content['merged_at'] || content['mergedAt'])
    closed_at = content['closed_at'] || content['closedAt']
    completed_at = content['state'] == 'closed' ? (merged_at || closed_at) : nil
    if content['state'] == 'closed' && completed_at.to_s.empty?
      raise ContractError, 'closed content has no completion timestamp'
    end

    {
      'createdAt' => created_at,
      'completedAt' => completed_at,
      'completionKind' => completed_at && (merged_at ? 'merged' : 'closed')
    }
  end

  def self.local_time(timestamp)
    Time.iso8601(timestamp).getlocal(TIME_ZONE_OFFSET)
  rescue ArgumentError, TypeError
    raise ContractError, "invalid event timestamp #{timestamp.inspect}"
  end

  def self.from_event(event)
    timestamps = timestamps_for(event)
    dates = {
      'submittedDate' => local_time(timestamps.fetch('createdAt')).strftime('%F'),
      'endDate' => timestamps['completedAt'] && local_time(timestamps['completedAt']).strftime('%F')
    }
    if event['pull_request']
      sections = PullRequestMetadata.sections(event['pull_request']['body'])
      dates.merge!(PullRequestMetadata.project_dates(sections['GitHub Project']).compact)
    end
    dates
  rescue PullRequestMetadata::ContractError => error
    raise ContractError, error.message
  end
end

if $PROGRAM_NAME == __FILE__
  options = {}
  parser = OptionParser.new do |opts|
    opts.banner = 'Usage: project-dates.rb resolve --event-file PATH'
    opts.on('--event-file PATH', 'Current GitHub Issue or pull request payload') { |value| options[:event_file] = value }
  end

  begin
    command = parser.parse(ARGV).shift
    raise OptionParser::InvalidArgument, parser.banner unless command == 'resolve'

    puts JSON.generate(ProjectDates.from_event(JSON.parse(File.read(options.fetch(:event_file)))))
  rescue ProjectDates::ContractError, KeyError, Errno::ENOENT, JSON::ParserError,
         OptionParser::ParseError, TypeError => error
    warn error.message
    exit 1
  end
end
