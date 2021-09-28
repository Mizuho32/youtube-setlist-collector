#!/usr/bin/env ruby

require 'optparse'

option = {

}

parser = OptionParser.new
parser.on('-i', "--init", "Initialize project") { option[:init] = true }
parser.on('-U', "--update", "Update uploaded videos") { option[:update] = true }
parser.on('-m', "--make", "Make setlist") { option[:make] = true }
  parser.on('-d songs.csv', "--song-db", "CSV file name of list of song names and artists") {|v| option[:song_db] = v }
  parser.on('-s Regexp', "--singing-stream", "Additional regexp to select singing streams") {|v|
    option[:singing_streams] = Regexp.new(v) }
  parser.on('-t Regexp', "--title-match", "Title regexp to select videos from singing streams") {|v|
    option[:title_match] = Regexp.new(v) }
  parser.on('-i Regexp', "--id-match", "ID regexp to select videos from singing streams") {|v|
    option[:id_match] = Regexp.new(v) }
  parser.on('-r range', "--range", "Select videos from singing streams by Ruby's range expr") {|v|
		option[:range] = Range.new(*v.split("..").map(&:to_i)) }
  parser.on('-f', "--force", "Overwrite existing setlist info") {|v| option[:force] = true }
parser.on("--search query", "Search channel by query") {|v| option[:search] =  v}

parser.on('-k KEY', "--api-key", "YouTube API Key file or value") {|v| option[:api_key] = v }
parser.on('-u URL', "--url", "YouTube channel url") {|v| option[:url] = v }
parser.on('--show', "Show text_original of comments") {|v| option[:show_text_original] = true }
parser.on('--fcc', "--force-cache-comment", "Force update comment cache") {|v| option[:force_cache_comment] = true }

begin
  parser.parse!(ARGV)
rescue StandardError
  STDERR.puts parser
  exit 1
end

if option[:url].to_s.empty? and not option[:search] then
  STDERR.puts("-u URL: Specify YouTube channel's URL and API ")
  exit 2
end
if %i[init update make search].map{|e| not option.keys.include? e}.all? then
  STDERR.puts("Specify one of them: --init, --update, --make")
  exit 3
end

require_relative "src/youtube_utils"
option[:api_key] = File.read(option[:api_key]) if File.exist?(option[:api_key])
youtube = Google::Apis::YoutubeV3::YouTubeService.new
youtube.key = option[:api_key]

if option.keys.include? :init then
  YTU.init_project(youtube, option[:url])
elsif option.keys.include?(:make) then
  if option[:song_db].to_s.empty? then
    STDERR.puts("-d songs.csv: Specify CSV file name of list of song names and artists")
    exit 4
  end

	require_relative "src/lib"
	song_db = get_song_db(option[:song_db])

	keys = %i[singing_streams title_match id_match range force show_text_original force_cache_comment]
	kw = option.select{|k,v| keys.include?(k) }
  channel2setlists(youtube, option[:url], song_db, **kw)
elsif option.keys.include?(:update) then
	require_relative "src/lib"
  YTU.get_uploads(youtube, YTU.url2channel_id(option[:url]))

elsif option.keys.include?(:search) then
  query = youtube.list_searches("snippet", q: option[:search], type: "channel")

  puts "Found #{query.items.size} results"
  query.items.each{|item|
    s = item.snippet
    puts s.title, "https://www.youtube.com/channel/#{s.channel_id}", ""
  }

end
