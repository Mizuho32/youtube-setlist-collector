require 'yaml'

require_relative "params"
require_relative "youtube_utils"

module Util
  extend self

  def song_freq(ident)
    channel_id = YTU.url2channel_id(ident)

    all_songs = Dir.glob(YTU::DATA_DIR / channel_id / YTU::STREAMS_DIR / "*.yaml")
      .map{|path|
        path = Pathname(path)
        [path.basename(path.extname).to_s.to_sym, YAML.load_file(path)]
      }
      .map{|id, yaml| yaml[:setlist].map{|row| row[:body][:song_name]} }
      .flatten.map{|name| name.gsub(/\([^\)]+(\)|$)|(\(|^)[^\)]+\)/, "") }

    grouped_songs = all_songs.group_by{|song| song.downcase.gsub(/\s+/,"") }
    stat = grouped_songs.map{|name, freq| [freq.first, freq.size]}.sort{|(_,l),(_,r)| l<=>r}.reverse
  end
end
