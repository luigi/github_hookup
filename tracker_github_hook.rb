#!/usr/bin/env ruby
#
# GitHub Post-Receive hook handler to add comments, and update state in Pivotal Tracker
# Configure your Tracker API key, and Project ID in a config.yml file placed in the
# same directory as this app.
# When you make commits to Git/GitHub, and want a comment and optionally a state update
# made to Tracker, add the following syntax to your commit message:
#     
#     [Story#####]
# or
#     [Story##### state:finished]
#

require 'rubygems'
require 'sinatra'
require 'json'
require 'rest_client'
require 'yaml'
require 'bitly'
require 'custom_isaac'

bitly = Bitly.new('luigi','R_e522ff53b511647eaa4ca05995eceb2c')
bot = nil
room = "#sunlightlabs"

# load up configuration from YAML file
configure do
  begin
    config = open(File.expand_path(File.dirname(__FILE__) + '/config.yml')) { |f| YAML.load(f) }    
    PROJECTS = Hash.new
    config.each do |project|
      raise "required configuration settings not found" unless project[1]['tracker_api_token'] && project[1]['tracker_project_id']    
      PROJECTS[project[1]['github_url']] = { :api_token => project[1]['tracker_api_token'], :project_id => project[1]['tracker_project_id'], :ref => project[1]['ref'] }
    end

    bot = Isaac::Bot.new
    eightball = [ "As I see it, yes",
                  "It is certain",
                  "It is decidedly so",
                  "Most likely",
                  "Outlook good",
                  "Signs point to yes",
                  "Without a doubt",
                  "Yes",
                  "Yes - definitely",
                  "You may rely on it",
                  "Reply hazy, try again",
                  "Ask again later",
                  "Better not tell you now",
                  "Cannot predict now",
                  "Concentrate and ask again",
                  "Don't count on it",
                  "My reply is no",
                  "My sources say no",
                  "Outlook not so good",
                  "Very doubtful" ]

    bot.configure do |c|
      c.nick    = "SunlightBot"
      c.server  = "irc.freenode.net"
      c.port    = 6667
    end

    bot.on :connect do
      join room
    end

    bot.on :channel, /SunlightBot:/ do
      msg channel, "#{nick}: " + eightball[rand(eightball.length)]
    end

    bot.helpers do
      def announce_commit(commit_message)
        msg channel, commit_message
      end
    end
    bot.start
  rescue => e
    puts "Failed to startup: #{e.message}"
    puts "Ensure you have a config.yml in this directory with the'tracker_api_token' and 'tracker_project_id' keys/values set."
    exit(-1)
  end
end

# The handler for the GitHub post-receive hook
post '/' do
  @num_commits = 0
  push = JSON.parse(params[:payload])
  
  push['commits'].each do |commit| 
    url = bitly.shorten(commit['url'])
    bot.msg room, "\002#{push['repository']['name']}\002 #{commit['message']} (#{commit['author']['name']}) #{url.short_url}"
  end
  
  tracker_info = PROJECTS[push['repository']['url']]
  unless tracker_info.nil?
    if tracker_info[:ref] && push['ref'] != tracker_info[:ref]
      puts "Skipping commit for non-tracked ref #{push['ref']}"
    end
    push['commits'].each { |commit| process_tracker_commit(tracker_info, commit) }
    "Processed #{@num_commits} commits for stories"
  end
end

get '/' do
    #bot.msg room, "Someone just visited me with a GET request..."
    "Have your github webhook point here; bridge works automatically via POST"
end

def process_tracker_commit(tracker_info, commit)
  message = "Commit: #{commit['message']} (#{commit['author']['name']}) - #{commit['url']}"

  # see if there is a Tracker story trigger, and if so, get story ID
  message.scan(/\[Story(\d+)([^\]]*)\]/) do |tracker_trigger|
    @num_commits += 1
    story_id = tracker_trigger[0]

    # post comment to the story
    RestClient.post(create_api_url(tracker_info[:project_id], story_id, '/notes'),
                    "<note><text>#{message}</text></note>", 
                    tracker_api_headers(tracker_info[:api_token]))
  
    # See if we have a state change
    state = tracker_trigger[1].match(/.*state:(\s?\w+).*/)
    if state
      state = state[1].strip

      RestClient.put(create_api_url(tracker_info[:project_id], story_id), 
                     "<story><current_state>#{state}</current_state></story>", 
                     tracker_api_headers(tracker_info[:api_token]))
    end     
  end
end

def process_irc_commit(commit)
  bot.msg room, "Commit: #{commit['message']} (#{commit['author']['name']}) - #{commit['url']}"
end

def create_api_url(project_id, story_id, extra_path_elemets='')
  "http://www.pivotaltracker.com/services/v1/projects/#{project_id}/stories/#{story_id}#{extra_path_elemets}"
end

def tracker_api_headers(api_token)
  { 'X-TrackerToken' => api_token, 'Content-type' => 'application/xml' }
end

  
