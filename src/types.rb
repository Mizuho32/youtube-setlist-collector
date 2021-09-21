module Types
  class SetlistError < StandardError
    attr_accessor :response
    def initialize(response)
      # comment_threads response
      @response = response
    end
  end

  class SetlistParseError < SetlistError
    attr_accessor :tmp_setlist, :text_original, :ex
    def initialize(response, tmp_setlist, text_original, ex)
      super(response)
      @tmp_setlist = tmp_setlist
      @text_original = text_original
      @ex = ex
    end
  end

  class NoSetlistCommentError < SetlistError
    attr_accessor :text_original
    def initialize(response, text_original)
      super(response)
      @text_original = text_original
    end
  end
end
