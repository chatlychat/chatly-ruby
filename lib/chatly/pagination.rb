# frozen_string_literal: true

module Chatly
  # One page of a cursor-paginated list endpoint, exactly as the API returned
  # it.
  #
  # The wire shape is `{"items":[...],"nextCursor":"..."|null}`. This wraps it
  # without rewriting it: `raw` is the decoded response, and `items` /
  # `next_cursor` are snake_case readers over the camelCase keys so Ruby code
  # reads like Ruby. The hashes inside `items` keep their camelCase keys --
  # see the README's "Shapes" note for why they are not converted.
  #
  # Only the seven genuinely paginated endpoints return one of these. A route
  # that answers with a bare array -- `GET /v1/macros` is the one -- returns
  # the Array, because wrapping a cursorless list in a page object invents a
  # `next_cursor` the server never offered.
  class Page
    include Enumerable

    attr_reader :items, :next_cursor, :raw

    def initialize(raw)
      @raw = raw
      hash = raw.is_a?(Hash) ? raw : {}
      @items = hash["items"].is_a?(Array) ? hash["items"] : []
      # `nextCursor` is the documented key. `next_cursor` is accepted too, so
      # that one endpoint shipping the snake_case spelling does not silently
      # end pagination after a single page.
      cursor = hash.key?("nextCursor") ? hash["nextCursor"] : hash["next_cursor"]
      @next_cursor = (cursor.is_a?(String) && !cursor.empty?) ? cursor : nil
    end

    def each(&block)
      @items.each(&block)
    end

    # True when the server says there is more. A null, absent or empty
    # cursor all mean "this was the last page".
    def more?
      !@next_cursor.nil?
    end

    def empty?
      @items.empty?
    end

    def size
      @items.size
    end

    def inspect
      "#<Chatly::Page items=#{@items.size} next_cursor=#{@next_cursor.inspect}>"
    end
  end

  # Cursor walking.
  #
  # Never page or sort on `id`: ids in this product are a mix of UUID v4 and
  # v7, so id order is not time order. The cursor is the only correct
  # sequence, and it is opaque -- do not parse it.
  module Pagination
    # Walk every page, yielding each item.
    #
    # Returns an `Enumerator`, which is the Ruby idiom and is lazy by
    # construction: `.first(10)` stops after the first page if the first page
    # holds ten items, `.lazy.select{}.first(3)` fetches only the pages it
    # needs, and `.each` walks to the end.
    #
    #   client.contacts.auto_list(limit: 100).each { |c| puts c["email"] }
    #   client.contacts.auto_list.lazy.map { |c| c["id"] }.first(5)
    #
    # Two stop conditions, and both are necessary:
    #
    #   1. a null/absent/empty `nextCursor` -- the normal end of the list;
    #   2. a cursor we have already requested -- a server that echoes the
    #      cursor it was given, or cycles between two, would otherwise spin
    #      forever re-yielding the same page and never raise anything.
    #
    # The repeated-cursor case ends the iteration quietly rather than
    # raising: a caller in the middle of streaming a million contacts is
    # better served by a short result they can detect than by an exception
    # from inside an `each`.
    #
    # @param query [Hash] the first page's query; `cursor` is managed here
    # @yieldparam page_query [Hash] called once per page, returns a Page
    # @return [Enumerator]
    def self.each_item(query = {}, &fetch)
      raise ArgumentError, "Pagination.each_item requires a fetch block" unless block_given?

      Enumerator.new do |yielder|
        each_page(query, &fetch).each do |page|
          page.items.each { |item| yielder << item }
        end
      end
    end

    # The same walk, a page at a time, for a caller who wants the page
    # boundaries (to checkpoint a cursor, or to batch-insert a page at once).
    #
    # @return [Enumerator]
    def self.each_page(query = {}, &fetch)
      raise ArgumentError, "Pagination.each_page requires a fetch block" unless block_given?

      Enumerator.new do |yielder|
        page_query = normalize(query)
        seen = {}
        seen[page_query[:cursor]] = true unless page_query[:cursor].nil?

        loop do
          page = fetch.call(page_query)
          page = Page.new(page) unless page.is_a?(Page)
          yielder << page

          cursor = page.next_cursor
          break if cursor.nil?
          break if seen.key?(cursor)

          seen[cursor] = true
          page_query = page_query.merge(cursor: cursor)
        end
      end
    end

    # Symbol keys throughout, so `{"cursor" => x}` and `{cursor: x}` do not
    # produce two different `cursor` parameters in the same query string.
    def self.normalize(query)
      return {} if query.nil?

      query.each_with_object({}) { |(key, value), out| out[key.to_sym] = value }
    end
    private_class_method :normalize
  end
end
