#!/usr/bin/env ruby
require 'bundler/inline'

gemfile do
  source 'https://rubygems.org'
  gem 'http'
  gem 'nap', require: 'rest'
  gem 'cocoapods', '~> 0.34.1'
  gem 'json'
  gem 'csv'
  gem 'addressable'
  gem 'optparse'
end

EVENTS_ENDPOINT_RESULT_LIMIT = 50 # Could be changed by Venmo without notice
MAX_EVENT_RECORDS_TO_RETRIEVE = 2000 # Script will stop once 2,000 records are fetched. Setting as a precaution.

def DISPLAY_USAGE_AND_EXIT
  puts "\nUsage: ruby venmo_history.rb [OPTIONS]\n\n"
  puts "    🗃  Export all of your venmo history to CSV."
  puts "    💻 Developed by Avery Ryder -> (Github: ryderpro)\n\n"
  puts "Required Options:\n\n"
  puts "  -d, -date [2018-01-01]   fetch transactions from now to past date"
  puts "  -t, -token [TOKEN]       access token to use Venmo API\n\n"
  puts "More Options:\n\n"
  puts "  -b, -before_id [ID]      Start after specific transaction_id"
  puts "  -h, -help                Show this message and exit.\n\n"
  exit
end

##### PARSE ARGUMENTS #####

@params = {} 
@username = nil
@user_id = nil
@last_date_to_include = nil

OptionParser.new do |parser|
  parser.on("-d STR", "--date", String)
  parser.on("-t STR", "--token", String)
  parser.on("-b STR", "--before_id", String)
  parser.on("-h STR", "---help") do
    DISPLAY_USAGE_AND_EXIT()
  end
end.parse!(into: @params)

unless @params[:date] || @params[:token]
  puts "\n🚷 Missing required arguments. Run $ ruby venmo_history.rb -help\n\n"
  exit  
end

@last_date_to_include = Date.parse(@params[:date])
@before_id_argument = @params[:before_id] if @params[:before_id]
puts "\n💎 Getting ready to fetch Venmos from now back to #{@params[:date]}...\n\n"

##### HELPERS #####

def get(path, params = {})
  headers = {:accept => "application/json", :cookie => "api_access_token=#{@params[:token]}"}
  url = venmo_url(path)
  response = HTTP.headers(headers).get(venmo_url(path), :params => params)
  puts "🐕 Fetching #{path} with #{params}... #{response.status}"
  unless response.status.success? 
    responseBody = response.parse
    puts "🚷 Error trying requesting #{path}...\n\n"
    puts "Error Message: #{responseBody["error"]["message"]}\n\n"
    exit
  end
  
  parsed_response = response.parse
  puts "🐕🐕🐕 Retrieved #{parsed_response["data"].count} records.\n\n" if parsed_response["data"]
  parsed_response
end

def venmo_url(path)  
  Addressable::URI.new({scheme: "https",host: "api.venmo.com",path: File.join("v1", path)})
end

def get_username_and_id
  self_response = get("me")
  @username = self_response["data"]["user"]["username"]
  @user_id = self_response["data"]["user"]["id"]
  if !@username || @username.to_s == '' || !@user_id || @user_id.to_s == ''
    puts "🚷 Exiting, test fetch for /me returned no username and/or id."
  end
  
  puts "💎 Found username - #{@username} \n\n"
end

# Results are sorted in descending order by "date_updated". Most recent events first.
def fetch_paginated_events(options = {})
  paginated_get("stories/target-or-actor/#{@user_id}", options)
end

def paginated_get(path, options = {})
  Enumerator.new do |y|
    query_params = {limit: EVENTS_ENDPOINT_RESULT_LIMIT}
    before_id = @params[:before_id] || nil
    total = 0
    max_results = options[:limit]
    date_lower_limit = options[:to_date]
    
    loop do
      query_params[:before_id] = before_id if before_id
      query_params[:limit] = max_results - total if (max_results - total) < EVENTS_ENDPOINT_RESULT_LIMIT
      response = get(path, query_params)
      
      data = response["data"]
      total += data.length
      
      data.each do |element|
        y.yield element
      end
      
      break if !response["pagination"]["next"]
      
      last_event_date = Date.parse(data.last["date_updated"])
      break if (data.empty? || total >= max_results || last_event_date <= date_lower_limit)
      before_id = data.last["id"]
    end
  end
end

##### MAIN #####

# Fetch username and userId
get_username_and_id

# Fetch events, will make potentially several calls to `/events` endpoint
events = fetch_paginated_events({limit: MAX_EVENT_RECORDS_TO_RETRIEVE, to_date: @last_date_to_include})
transactions = []

events.map { |event|
  hash = {:id => event["id"]}
  
  case event["type"]
  when "payment"
    user_paid_you = event["payment"]["action"] == "pay" && event["payment"]["actor"]["username"] != @username
    you_paid_user = event["payment"]["action"] == "pay" && event["payment"]["actor"]["username"] == @username
    you_charged_user = event["payment"]["action"] == "charge" && event["payment"]["actor"]["username"] == @username
    user_charged_you = event["payment"]["action"] == "charge" && event["payment"]["actor"]["username"] != @username
    display_name = user_paid_you || user_charged_you ? event["payment"]["actor"]["display_name"] : event["payment"]["target"]["user"]["display_name"] || "unknown"
    description = "#{event["payment"]["action"].upcase} #{display_name} for #{event["payment"]["note"]}".gsub("\n",' ').gsub(",",' ').gsub("-",' ')

    # date_completed is date_created if you paid user. 
    # I found a few Venmo records where date_completed was several years after the payment happened.
    date_completed = you_paid_user ? event["date_created"] : event["payment"]["date_completed"]

    hash.merge!(
      {
        :date_completed => Date.parse(date_completed || event["date_updated"]),
        :description => description,
        :amount => event["payment"]["amount"],
        :name => display_name
      }
    )
    
    if you_paid_user || user_charged_you
      hash[:amount] *= -1
    end
    
  when "transfer"
    hash.merge!(
      {
        :date_completed => Date.parse(event["transfer"]["destination"]["transfer_to_estimate"]),
        :description => "#{event["type"].upcase}",
        :amount => -event["transfer"]["amount"],
        :name => "#{event["transfer"]["destination"]["name"]} #{event["transfer"]["destination"]["last_four"]}",
      }
    )
    
  when "refund"
    hash.merge!(
      {
        :date_completed => Date.parse(event["refund"]["estimated_arrival"]),
        :description => "#{event["type"].upcase}, venmo might not have been received.",
        :amount => event["refund"]["amount"],
        :name => "#{event["refund"]["destination"]["name"]}",
      }
    )
    
  else
    puts "⚠️ Found unknown event found. Fix directly in your CSV file.\n\n #{event} \n\n"
    hash.merge!(
      {
        :date_completed => event["date_updated"],
        :description => "unknown",
        :amount => 0,
        :name => "unknown",
      }
    )
  end
  
  transactions << hash if hash[:date_completed] >= @last_date_to_include
}

transactions.map { |record|
  record[:date_completed] = record[:date_completed].strftime("%D")
}

file_name = "venmos_#{transactions.first[:date_completed].gsub("/","")}_to_#{transactions.last[:date_completed].gsub("/","")}.csv"
puts "💎 Exporting #{transactions.length} transactions. Look for #{file_name}."

CSV.open(file_name, "wb") do |csv|
  csv << transactions.first.keys
  transactions.each do |hash|
    csv << hash.values
  end
end

puts "✅ Finished.\n\n#{"🔨"*25}\n\n"