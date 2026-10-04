#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'optparse'

# Renders the single bot comment that records the source item's lifecycle.
module ItemTimeline
  class ContractError < StandardError; end

  def self.from_event(event)
    content = event['pull_request'] || event['issue']
    raise ContractError, 'event contains no Issue or pull request' if content.nil?

    created_at = content['created_at'] || content['createdAt']
    raise ContractError, 'content has no created timestamp' if created_at.to_s.empty?

    pull_request = event.key?('pull_request')
    merged_at = pull_request && (content['merged_at'] || content['mergedAt'])
    closed_at = content['closed_at'] || content['closedAt']
    completed_at = content['state'] == 'closed' ? (merged_at || closed_at) : nil
    completion_kind = if merged_at && completed_at
                        'merged'
                      elsif completed_at
                        'closed'
                      end

    {
      'createdAt' => created_at,
      'completedAt' => completed_at,
      'completionKind' => completion_kind
    }
  end

  def self.render(event)
    timeline = from_event(event)
    completed = if timeline['completedAt']
                  "`#{timeline['completedAt']}` (#{timeline['completionKind']})"
                else
                  'Pending'
                end

    <<~MARKDOWN
      <!-- zshell-item-timeline -->

      ### Timeline

      - Submitted: `#{timeline['createdAt']}`
      - Completed: #{completed}
    MARKDOWN
  end
end

def command_render(options)
  event = JSON.parse(File.read(options.fetch(:event_file)))
  puts ItemTimeline.render(event)
end

if $PROGRAM_NAME == __FILE__
  options = {}
  parser = OptionParser.new do |opts|
    opts.banner = 'Usage: item-timeline.rb render --event-file PATH'
    opts.on('--event-file PATH', 'GitHub event payload') { |value| options[:event_file] = value }
  end

  command = parser.parse(ARGV).shift
  begin
    raise OptionParser::InvalidArgument, parser.banner unless command == 'render'

    command_render(options)
  rescue ItemTimeline::ContractError, KeyError, Errno::ENOENT, JSON::ParserError,
         OptionParser::ParseError, TypeError => error
    warn error.message
    exit 1
  end
end
