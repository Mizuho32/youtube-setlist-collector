# coding: utf-8

require 'csv'
require 'pp'
require 'yaml'

require 'nkf'
require 'moji'

require_relative "params"
require_relative "types"
require_relative "sheet"
require_relative "youtube_utils"

#load "src/types.rb" # FIXME
#load "src/youtube_utils.rb"


def item2snippet(item)
  return item.snippet.top_level_comment.snippet
end

def item2text_orig(item)
  return item.snippet.top_level_comment.snippet.text_original
end

def preprocess(text_original)
  NKF::nkf("-wZ0", text_original.gsub(/\r/, ""))
end

$setlist_reg = /(?:set|songs?|セッ?ト|曲).*(?:list|リ(スト)?)/i
$symbol = %Q<!@#$%^&*()_+-=[]{};':"\\,|.<>/?〜>
$symbol_reg = /[#{Regexp.escape($symbol)}]|#{Moji.regexp(Moji::ZEN_SYMBOL)}/

$time_reg = /(?:\d+:)+\d+/
# line that has timestamp in first row, no time stamp nor symbol only line follows
$line_reg = /[^\n]+#{$time_reg}[^\n]+(?:\n(?!(?:.+#{$time_reg}.+|(?:#{$symbol_reg})+))[^\n]+)*/
$list_reg = /(?:#{$line_reg}(?:\n){0,2}){2,}/ # TODO: auto detect num of LF

$line_ignore_reg = /start|スタート/i
$ignore_reg = /(?:^\s*\d+(?:\.|\s)|　)/

def get_setlist(text_original, song_db, select_thres = 0.5)
  m = if $setlist_reg =~ text_original then
    text_original.split($setlist_reg).last
  else
    text_original
  end.match($list_reg)

  return [], text_original, [] if m.nil?

  tmp_setlist = m[0]
    .strip.scan($line_reg)
    .select{|el| not el.match($line_ignore_reg) }
    .map{|el|
      time = el.scan($time_reg)
      m = el.sub($ignore_reg, "").split($time_reg) # split by timestamp
      body = m.first.size > m.last.size ? m.first : m.last
      { time: time,
        lines: lines=body.split("\n").map{|line| line.strip}
      }
    }

  # find splitter and split body by splitter
  splitters = get_split_symbols(tmp_setlist, select_thres)
  splt_reg = splitters.map{|e|
    next "(?:(?<![a-z])#{e}|#{e}(?![a-z]))" if e =~ /^\s+$/
    Regexp.escape(e)
  }
  splt_reg = splitters.empty? ? /$/ : /(?:#{ splt_reg.join("|") })/
  tmp_setlist.select!{|el| el[:lines].first.match(splt_reg) }
  tmp_setlist.each{|el|
    el[:splitted] = el[:lines]
      .first.split(splt_reg)
      .select{|splt| not splt.empty? and splt !~ /^(?:\s|#{$symbol_reg})+$/ }
  }
  # map song_name and artist
  indices = indices_of_songinfo(song_db, tmp_setlist)
  setlist = tmp_setlist.each{|line| line[:body] =  splitted2songinfo(line[:splitted], indices, song_db) }
  return setlist, text_original, splitters
rescue StandardError => ex
  puts "FAILED while parsing", ex.message, "---", text_original
  #pp tmp_setlist
  raise Types::SetlistParseError.new(nil, tmp_setlist, text_original, ex)
end

def get_split_symbols(tmp_setlist, select_thres)
  lines = tmp_setlist.map{|el| el[:lines][0]}
  symbol_group = lines
    .map{|line| line.scan(/(?:(?!\s+[a-z])(?:\s|#{$symbol_reg})+|By)/i).uniq }
    .flatten.group_by{|k,v| k}

  if symbol_group.empty? then # Zenkaku symbols
    symbol_group = lines
      .map{|line|
        # Zenkaku symbol substrings
        line.each_char.chunk{|char| Moji.type?(char, Moji::ZEN_SYMBOL)}.select{|is_symbol, chars| is_symbol}.map{|_, chars| chars.join}.uniq
      }.flatten.group_by{|k,v| k}
  end

  symbol_group_stat = Hash[symbol_group.map{|k,v| [k, v.size.to_f]}]
  symbol_group_stat.keys.combination(2).each{|k1, k2|
    if k1.include?(k2) then
      symbol_group_stat[k2] += symbol_group_stat[k1]
    elsif k2.include?(k1) then
      symbol_group_stat[k1] += symbol_group_stat[k2]
    end
  }
  symbol_group_stat.select{|k,n| n/lines.size > select_thres}.keys
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

def splitted2songinfo(splitted, indices, song_db)
  song_name_idx = indices[:song_name]&.first || splitted.size
  artist_idx    = indices[:artist]&.first || splitted.size
  song_name = splitted[song_name_idx]
  artist    = splitted[artist_idx]

  if song_name.nil? then
    _splitted = splitted.reject{|n| n==artist}
    if song_name_idx >= _splitted.size # invalid song_name index
      if _splitted.size==1
        song_name = _splitted.first
      else
        if not (searched = _splitted.select{|itm| song_db[:song_name].index(itm)}).empty?
          song_name = searched.first
        else
          song_name = _splitted.first
        end
      end
    else
      song_name = if song_name_idx < artist_idx then
        _splitted.first
      else
        _splitted.last
      end
    end
  end

  if artist.nil?
    if splitted.size != 1
      artist = if song_name_idx < artist_idx then
        splitted.last
      else
        splitted.first
      end
    else
      if idx = song_db[:song_name].index(song_name) then
        artist = song_db[:artist][idx]
      end
    end
  end


  return {song_name: song_name.to_s.strip, artist: artist.to_s.strip}
end


def get_song_db(csv_location)
return CSV.read(csv_location)[1..]
    .inject({song_name: [], artist:[]}){|h, row|
        h[:song_name] << row.first.downcase
        h[:artist] << row.last.downcase
        h
    }
end

def looks_comment_setlist?(text_original)
  text_original.match($setlist_reg) or text_original.match($list_reg)
end

def video2looks_setlists(youtube, videoId: "", maxResults: 20, response: nil)
  response = youtube.list_comment_threads('snippet', video_id: videoId.to_s, max_results: maxResults) if response.nil?

  lsl = response.items.map{|el|
    [el, preprocess( item2text_orig(el) )]
  }.select{|el, text_original|
    looks_comment_setlist?(text_original)
  }.sort{|(lel,ltext_original), (rel,rtext_original)|
    lel.snippet.top_level_comment.snippet.like_count <=> rel.snippet.top_level_comment.snippet.like_count
  }.reverse
  return lsl, response
end

def video2setlist(youtube, song_db, videoId: "", maxResults: 20, response: nil)
  looks_str_setlists, response = video2looks_setlists(youtube, videoId: videoId, maxResults: maxResults, response: response)

  set_list, txt, splitters = [], "", []
  looks_str_setlists.each{|el, text_original|
  begin
    txt = text_original
    set_list, text_original, splitters = get_setlist(text_original, song_db)
    break if not set_list.empty?
  rescue Types::SetlistParseError => ex
    ex.response = response
    raise ex
  end
  }
  raise Types::NoSetlistCommentError.new(response, txt) if set_list.empty?

  return set_list, txt, splitters, response
end

$singing_streams = /歌枠|singing\s+stream/i
def channel2setlists(youtube, channel_url, song_db, singing_streams:nil, title_match:nil, id_match:nil, range:0..-1, force: false)
  singing_streams = singing_streams.nil? ? $singing_streams : /#{singing_streams}|#{$singing_streams}/
  channel_id = YTU.url2channel_id(channel_url)
  data_dir = Pathname(YTU::DATA_DIR)
  channel_dir = data_dir / channel_id

  # select singing streams
  csv_format = YTU::UPLOADS_CSV_FORMAT
  uploads = CSV.read(channel_dir / YTU::UPLOADS_CSV)
    .select{|line|
      title = line[csv_format[:title]]
      id = line[csv_format[:id]]
      title.match(singing_streams) and (
        (not !title_match.nil? or title.match(title_match)) and # not nil? -> match
        (not !id_match.nil?    or id.match(id_match))          )
    }[range]
  puts "SELECTED:", "---", uploads.map{|line| "#{line[csv_format[:title]]} (#{line[csv_format[:id]]})" }.join("\n"), "---"

  # make setlists
  streams_dir = data_dir / channel_id / YTU::STREAMS_DIR
  fails = uploads.map{|line|
  begin
    id = line[csv_format[:id]]
    title = line[csv_format[:title]]
    yamlfile_name = streams_dir / "#{id}.yaml"
    next if File.exist?(yamlfile_name) and not force

    comment_cache = channel_dir / YTU::COMMENT_CACHE_DIR / "#{id}.yaml"
    cache = File.exist?(comment_cache) ? YAML.load_file(comment_cache) : {}
    response = cache[:response]

    puts "Analyze #{title}(#{id})..."
    set_list, text, splitters, response = video2setlist(youtube, song_db, videoId: id, response: response)
    yaml = {title: title, id: id, splitters: splitters, setlist: set_list, text_original: text}.to_yaml
    File.write(yamlfile_name, yaml) if not File.exist?(yamlfile_name) or force

  rescue Types::SetlistParseError => ex
    File.write(comment_cache, {errmsg: ex.ex.message+"\n"+ex.ex.backtrace.join("\n"), response: ex.response, tmp_setlist: ex.tmp_setlist, text_original: ex.text_original}.to_yaml)
    next [title, id, ex.class.to_s]
  rescue Types::NoSetlistCommentError => ex
    puts msg="Setlist comment not found for #{title}(#{id})"
    puts ex.text_original
    File.write(comment_cache, {errmsg: msg, response: ex.response, text_original: ex.text_original}.to_yaml)
    next [title, id, ex.class.to_s]
  end
    File.write(comment_cache, {response: response}.to_yaml) if not File.exist?(comment_cache)
    nil
  }.compact

  CSV.open(channel_dir / YTU::FAILS_CSV, "wb") do |csv|
    fails.each{|row| csv << row }
  end
end


def insert_videos_to_sheet(sheet,
  # video select params
  channel_id, singing_streams:nil, title_match:nil, id_match:nil, range:0..-1,
  # sheet style params
  previous_setlist_even: 0) # 0 is true

  singing_streams = singing_streams.nil? ? $singing_streams : /#{singing_streams}|#{$singing_streams}/
  channel_dir = YTU::DATA_DIR / channel_id
  csv_format = YTU::UPLOADS_CSV_FORMAT

  selected = CSV.read(channel_dir / YTU::UPLOADS_CSV)
      .select{|line|
        title = line[csv_format[:title]]
        id = line[csv_format[:id]]
        title.match(singing_streams) and (
          (not !title_match.nil? or title.match(title_match)) and # not nil? -> match
          (not !id_match.nil?    or id.match(id_match))          )
      }[range]

  puts "SELECTED:", "---", selected.map{|line| "#{line[csv_format[:title]]} (#{line[csv_format[:id]]})" }.join("\n"), "---"

  sc = sheet_conf = YAML.load_file(channel_dir / Params::Sheet::SHEET_CONF)
  %i[tbc tfc rbc].each{|key| sheet_conf[key] = sheet_conf[key].map{|color| SheetsUtil.htmlcolor(color)} }
  streams_dir = channel_dir / Params::YouTube::STREAMS_DIR

  selected.reverse.each_with_index{|row, i|
    yaml = streams_dir / (row[csv_format[:id]] + ".yaml")
    if not File.exist?(yaml) then
      puts "Skip #{row.join(" ")}"
      next
    end

    video = YAML.load_file(yaml)
    SheetsUtil.insert_video!(sheet, sc[:sheet_id], sc[:gid], sc[:start_row], sc[:start_column], video, i,
                     row_idx_offset: previous_setlist_even+video[:setlist].size%2, # FIXME
                     title_back_colors: sc[:tbc], title_fore_colors: sc[:tfc], row_back_colors: sc[:rbc])
    previous_setlist_even = video[:setlist].size % 2
  }
end
