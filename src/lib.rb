# coding: utf-8

require 'csv'
require 'pp'

require 'nkf'

require_relative "youtube_utils"


def item2text_orig(item)
  return item.snippet.top_level_comment.snippet.text_original
end

def preprocess(text_original)
  NKF::nkf("-wZ0", text_original.gsub(/\R/, "\n"))
end

$symbol_reg = /[!@#\$%\^&\*\(\)_\+-=\[\]\{\};':"\\,\|\.<>\/\?]/

$time_reg = /(?:\d+:)+\d+/
$line_reg = /[^\n]+#{$time_reg}[^\n]+(?:\n(?!.+#{$time_reg}.+)[^\n]+)*/
$list_reg = /(?:#{$line_reg}(?:\n){0,2}){2,}/ # TODO: auto detect num of LF

$line_ignore_reg = /start|スタート/i
$ignore_reg = /^\s*\d+\.?/

def get_setlist(text_original, song_db, select_thres = 0.5)
  m = text_original.match($list_reg)
  return {}, text_original if m.nil?

  tmp_setlist = m[0]
    .strip.scan($line_reg)
    .select{|el| not el.match($line_ignore_reg) }
    .map{|el|
      time = el.scan($time_reg)
      m = el.sub($time_reg, "")
        .sub($ignore_reg, "")
        .strip # 1st row is only time stamp
        #.tap{|el| p el}
        .match(/^(.*)$/)
      body =  m[1]
      { time: time,
        lines: lines=body.split("\n").map{|line| line.strip}
      }
    }

  # find splitter and split body by splitter
  splitters = get_split_symbols(tmp_setlist, select_thres).join("|")
  tmp_setlist.select!{|el| el[:lines].first.match(/(?:#{splitters})/) }
  tmp_setlist.each{|el| el[:splitted] = el[:lines].first.split(/(?:#{splitters})/) }
  indices = indices_of_songinfo(song_db, tmp_setlist)
  setlist = tmp_setlist.each{|line| line[:body] =  splitted2songinfo(line[:splitted], indices) }
  return setlist, text_original
rescue NoMethodError => ex
  puts "FAILED while processing:","---", text_original
  pp tmp_setlist
  raise ex
end

def get_split_symbols(tmp_setlist, select_thres)
  lines = tmp_setlist.map{|el| el[:lines][0]}
  symbol_group = lines
    .map{|line| line.scan(/(?:\s|#{$symbol_reg})+/).uniq }
    .flatten.group_by{|k,v| k}
  symbol_group.select{|k,v| v.size/lines.size.to_f > select_thres}.keys
end

def indices_of_songinfo(song_db, tmp_setlist, sample_rate: 0.5, max_sample: 50)
  len = (tmp_setlist.size*sample_rate).to_i
  len = [tmp_setlist.size, max_sample].min if len > max_sample

  # search indices in song_db
  info_indices = tmp_setlist[0...len].inject({}){|h, el|
    el[:splitted].each_with_index do |info, i|
      song_db.each{|info_type, db|
        idx = db.index(info.downcase)
        h[info_type] = (h[info_type] or []) << i if not idx.nil?
        #h[:splitted] = el[:splitted]
      }
    end
    h
  }
  #p "info", info_indices

  # calc statistics
  info_indices.map{|info_type, idx|
    idx_distri = idx
      .group_by(&:itself)
      .map{|idx, amount| [idx, amount.size]}
      .sort{|(lidx, lsize),(ridx, rsize)| lsize <=>rsize}.reverse
    [info_type, idx_distri.map{|(idx, size)| idx}]
  }.to_h
end

def splitted2songinfo(splitted, indices)
  song_name_idx, artist_idx = indices[:song_name].first, indices[:artist].first
  song_name, artist = splitted[song_name_idx], splitted[artist_idx]

  if song_name.nil?
    song_name = if song_name_idx < artist_idx then
      splitted.first
    else
      splitted.last
    end
  end

  if artist.nil?
    artist = if song_name_idx < artist_idx then
      splitted.last
    else
      splitted.first
    end
  end

  return {song_name: song_name.to_s, artist: artist.to_s}
end





$setlist_reg = /(set|songs?|セッ?ト|曲).*(list|リ(スト)?)/i
def looks_comment_setlist?(text_original)
  text_original.match($setlist_reg) or text_original.match($list_reg)
end

def video2looks_setlists(youtube, videoId: "", maxResults: 20, response: nil)
  response = youtube.list_comment_threads('snippet', video_id: videoId.to_s, max_results: maxResults) if response.nil?

  response.items.map{|el|
    [el, preprocess( item2text_orig(el) )]
  }.select{|el, text_original|
    looks_comment_setlist?(text_original)
  }.sort{|(lel,ltext_original), (rel,rtext_original)|
    lel.snippet.top_level_comment.snippet.like_count <=> rel.snippet.top_level_comment.snippet.like_count
  }.reverse
end

def video2setlist(youtube, song_db, videoId: "", maxResults: 20, response: nil)
  looks_str_setlists = video2looks_setlists(youtube, videoId: videoId, maxResults: maxResults, response: response)

  set_list = []
  looks_str_setlists.each{|el, text_original|
    set_list, text_original = get_setlist(text_original, song_db)
    break if not set_list.empty? and not set_list.is_a? String
  }

  return set_list, text_original
end

$singing_streams = /歌枠|singing\s+stream/i
def channel2setlists(youtube, channel_url, song_db, singing_streams://, title_match:nil, id_match:nil)
  singing_streams = /#{singing_streams}|#{$singing_streams}/
  channel_id = YTU.url2channel_id(channel_url)
  data_dir = Pathname(YTU::DATA_DIR)

  # select singing streams
  csv_format = YTU::UPLOADS_CSV_FORMAT
  uploads = CSV.read(data_dir / channel_id / YTU::UPLOADS_CSV)
    .select{|line|
      title = line[csv_format[:title]]
      id = line[csv_format[:id]]
      title.match(singing_streams) and (
        (! title_match.nil? and title.match(title_match)) or
        (! id_match.nil?    and id.match(id_match))          )
    }
  puts "SELECTED:", "---", uploads.map{|line| line[csv_format[:title]]}.join("\n")

  streams_dir = data_dir / channel_id / YTU::STREAMS_DIR
  uploads.each{|line|
    id = line[csv_format[:id]]
    title = line[csv_format[:title]]
    yamlfile_name = streams_dir / "#{id}.yaml"
    next if Dir.exist?(file_name)

    puts id
    set_list, text = video2setlist(youtube, song_db, videoId: id)
    yaml = {title: title, id: id, setlist: set_list, text_original: text}.to_yaml
    File.write(yamlfile_name, yaml) if not Dir.exist?(yamlfile_name)
  }
end
