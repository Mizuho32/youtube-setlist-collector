# coding: utf-8

require 'nkf'


def item2text_orig(item)
  return item.snippet.top_level_comment.snippet.text_original
end

def preprocess(text_original)
  NKF::nkf("-wZ0", text_original.gsub(/\R/, "\n"))
end

$symbol_reg = /[!@#\$%\^&\*\(\)_\+-=\[\]\{\};':"\\,\|\.<>\/\?]/

$time_reg = /(?:\d+:)+\d+/
$line_reg = /[^\n]+#{$time_reg}[^\n]+(?:\n(?!.+#{$time_reg}.+)[^\n]+)*/
$list_reg = /(?:#{$line_reg}(?:\n){1,2}){2,}/

def get_setlist(text_original, song_db, select_thres = 0.5)
  m = text_original.match($list_reg)
  return text_original if m.nil?

  tmp_setlist = m[0]
    .strip.scan($line_reg)
    .map{|el| 
      time = el.scan($time_reg)
      m = el.match(/^(.*)#{$time_reg}(.*)$/)
      body =  m[1].size > m[2].size ? m[1] : m[2]
      { time: time,
        lines: lines=body.split("\n").map{|line| line.strip}
      }
    }

  splitters = get_split_symbols(tmp_setlist, select_thres).join("|")
  tmp_setlist.each{|el|
    el[:splitted] = el[:lines].first.split(/(?:#{splitters})/)
  }
  indices = indices_of_songinfo(song_db, tmp_setlist)
  tmp_setlist.each{|line| line[:body] =  splitted2songinfo(line[:splitted], indices) }
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
  len = max_sample if len > max_sample

  info_indices = tmp_setlist[0...len].inject({}){|h, el|
    el[:splitted].each_with_index do |info, i|
      song_db.each{|info_type, db| 
        idx = db.index(info)
        h[info_type] = (h[info_type] or []) << i if not idx.nil?
        #h[:splitted] = el[:splitted]
      }
    end
    h
  }
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
    set_list = get_setlist(text_original, song_db)
    break if not set_list.empty?
  }

  return set_list
end
