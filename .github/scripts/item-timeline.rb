#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'optparse'

require_relative 'project-dates'

# Renders the single bot comment that records the source item's lifecycle.
module ItemTimeline
  ContractError = ProjectDates::ContractError

  def self.from_event(event)
    ProjectDates.timestamps_for(event)
  end

  def self.format_time(timestamp)
    ProjectDates.local_time(timestamp).strftime('%F %T UTC%:z')
  end

  def self.render(event)
    timeline = from_event(event)
    completed = if timeline['completedAt']
                  "`#{format_time(timeline['completedAt'])}` (#{timeline['completionKind']})"
                else
                  'Pending'
                end

    <<~MARKDOWN
      <!-- zshell-item-timeline -->

      ### Timeline

      - Submitted: `#{format_time(timeline['createdAt'])}`
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
