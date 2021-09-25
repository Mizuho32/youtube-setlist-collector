
module Params
  DATA_DIR = Pathname("data")
  module YouTube
    # YouTube
    CHANNELS_CSV = "channels.csv"
    CHANNELS_CSV_FORMAT = %i[name id sheet_id, sheet_url].each_with_index.map{|e,i| [e, i]}.to_h
    CHANNEL_INFO_YAML = "info.yaml"
    UPLOADS_CSV = "uploads.csv" # title, id, status
    UPLOADS_CSV_FORMAT = %i[title id status].each_with_index.map{|e,i| [e, i]}.to_h
    FAILS_CSV = "fails.csv"

    DATA_DIR = Params::DATA_DIR
    CACHE_DIR = "cache"
    STREAMS_DIR = "singing_streams"
    COMMENT_CACHE_DIR = Pathname(CACHE_DIR) / "comment"

    MAX_RESULTS = 50
  end

  module Sheet
    SHEET_CONF = "sheet.yaml"
  end

  module Drive
  end

end
