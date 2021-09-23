require 'fileutils'
require "csv"
require 'yaml'

require 'google/apis/youtube_v3'

module YTU
  extend self
  CHANNELS_CSV = "channels.csv"
  CHANNEL_INFO_YAML = "info.yaml"
  UPLOADS_CSV = "uploads.csv" # title, id, status
  UPLOADS_CSV_FORMAT = %i[title id status].each_with_index.map{|e,i| [e, i]}.to_h
  FAILS_CSV = "fails.csv"

  DATA_DIR = "data"
  CACHE_DIR = "cache"
  STREAMS_DIR = "singing_streams"
  COMMENT_CACHE_DIR = Pathname(CACHE_DIR) / "comment"

  MAX_RESULTS = 50

  def url2channel_id(url)
    return url if url =~ /^[^\/]+$/ # id?
    url[%r|youtube\.com/channel/(?<id>[^/]+)|, :id]
  end

  def init_project(youtube, channel_url, data_dir: Pathname(DATA_DIR))
    FileUtils.mkdir(data_dir) if not Dir.exist?(data_dir)

    channels_csv = CSV.read(data_dir / CHANNELS_CSV) rescue []
    channel_id = url2channel_id(channel_url)

    channels = youtube.list_channels("snippet,contentDetails", id: channel_id)
    if channels.items.nil? or channels.items.empty? then
      STDERR.puts "Invalid channel #{channel_url}"
      return 2
    end

    if not (hit=channels_csv.select{|(title, chid)| chid == channel_id}).empty? then
      STDERR.puts "WARN: Channel #{channel_url} already exists!"
    end

    channel = channels.items.first
    channel_title = channel.snippet.title
    channels_csv << [channel_title, channel_id]

    CSV.open(data_dir / CHANNELS_CSV, "wb") do |csv|
      channels_csv.uniq.each{|row| csv << row }
    end

    channel_dir = data_dir / channel_id
    FileUtils.mkdir(channel_dir) if not Dir.exist?(channel_dir)
    FileUtils.mkdir(channel_dir / STREAMS_DIR) if not Dir.exist?(channel_dir / STREAMS_DIR)
    FileUtils.mkdir(channel_dir / CACHE_DIR) if not Dir.exist?(channel_dir / CACHE_DIR)
    FileUtils.mkdir(channel_dir / COMMENT_CACHE_DIR) if not Dir.exist?(channel_dir / COMMENT_CACHE_DIR)
    File.write(channel_dir / CHANNEL_INFO_YAML, channel.to_yaml) if not File.exist?(channel_dir / CHANNEL_INFO_YAML)

    get_uploads(youtube, channel_id, channel: channel)
  end

  def get_uploads(youtube, channel_id, data_dir: Pathname(DATA_DIR), channel: nil)
    channel_dir = data_dir / channel_id
    channel = YAML.load_file(channel_dir / CHANNEL_INFO_YAML) if channel.nil?

    channel_stat = youtube.list_channels("statistics", id: channel_id).items.first

    video_count = channel_stat.statistics.video_count
    uploads = CSV.read(channel_dir / UPLOADS_CSV) rescue []
    playlist_id = channel.content_details.related_playlists.uploads

    puts "#{video_count} videos on the online, #{uploads.size} on the local"
    delta =
    if uploads.empty? then
      load_uploads(youtube, video_count, playlist_id)
    elsif uploads.size < video_count then
      load_uploads(youtube, video_count-uploads.size, playlist_id)
    elsif uploads.size > video_count then
      raise NotImplementedError.new
    else # uploaded == cached
      puts "Local data is updated. Nothing to do"
      return
    end
    uploads = delta + uploads
    puts "Updated Delta (#{delta.size})","----", delta.map{|row| row.join(", ")}.join("\n"), "----"

    CSV.open(channel_dir / UPLOADS_CSV, "wb") do |csv|
      uploads.each{|row| csv << row }
    end
  end

  def load_uploads(youtube, count, playlist_id)
    max_result = count > MAX_RESULTS ? MAX_RESULTS : count

    uploads = []
    token = nil
    loop do
      playlist = youtube.list_playlist_items("snippet,contentDetails", playlist_id: playlist_id, page_token: token, max_results: max_result)
      uploads += playlist.items.map{|v| [v.snippet.title, v.content_details.video_id, "public"] }
      token = playlist.next_page_token
      break if token.nil? or uploads.size >= count
    end

    return uploads
  end
end
