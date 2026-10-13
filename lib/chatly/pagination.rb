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
  # Only the ten genuinely paginated endpoints return one of these. A route
  # that answers with a bare array -- `GET /v1/macros` is the one -- returns
  # the Array, because wrapping a cursorless list in a page object invents a
  # `next_cursor` the server never offered.
  #
  # And a body that is not an envelope is an ERROR here, not an empty page.
  # See `coerce` below for the bug that rule exists to prevent.
  class Page
    include Enumerable

    attr_reader :items, :next_cursor, :raw

    def initialize(raw)
      @raw = raw
      hash = coerce(raw)
      @items = hash["items"]
      # `nextCursor` is the documented key. `next_cursor` is accepted too, so
      # that one endpoint shipping the snake_case spelling does not silently
      # end pagination after a single page.
      cursor = hash.key?("nextCursor") ? hash["nextCursor"] : hash["next_cursor"]
      @next_cursor = (cursor.is_a?(String) && !cursor.empty?) ? cursor : nil
    end

    # What a body IS, in a sentence, for the error below. Kept short: the
    # whole body can be a megabyte of contacts.
    def self.describe(raw)
      case raw
      when nil then "no body at all"
      when Array then "a bare JSON array (#{raw.length} element(s))"
      when Hash then "an object whose keys are #{raw.keys.map(&:to_s).sort.inspect}"
      else "a #{raw.class}"
      end
    end

    def each(&block)
      @items.each(&block)
    end

    # True when the server says there is more. A null, absent or empty
    # cursor all mean "this was the last page".
    def more?
      !@next_cursor.nil?
    end

    # Read a field from the ENVELOPE beside the items.
    #
    # Three paginated routes carry more than a page: `search.query` answers
    # with `facets` (per-entity totals ignoring the `kinds` filter) and a
    # `tier` (which backend produced the page), and
    # `conversations.unattended` carries a `total`. A paginator that exposed
    # only `items` would throw those away, so they are here rather than
    # buried:
    #
    #   results = client.search.query("refund")
    #   results.items        # => the hits
    #   results["facets"]    # => {"conversation" => 12, "ticket" => 3, ...}
    #   results["tier"]      # => "postgres"
    #
    # An Integer key raises rather than returning nil. `page[0]` looks like
    # "the first item" and would never be one -- items come off `items`,
    # `first` or any Enumerable method.
    def [](key)
      if key.is_a?(Integer)
        raise TypeError,
              "Chatly::Page#[] reads the response envelope by name (e.g. page[\"facets\"]). " \
              "For the items use page.items, page.first, or any Enumerable method."
      end

      @raw.is_a?(Hash) ? @raw[key.to_s] : nil
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

    private

    # A page is an ENVELOPE -- an object with an `items` array -- and
    # anything else raises.
    #
    # This used to read `raw.is_a?(Hash) ? raw : {}`, which turned a body
    # that is not a page into a Page with no items and no cursor. The
    # consequence was silent: `auto_list` over a route that answers with a
    # bare array yielded nothing, finished normally, and read as "this
    # workspace has no contacts". The same mistake reached production in two
    # sibling SDKs from the other side -- a paginator built over
    # `GET /v1/macros`, which is `@PaginationExempt` -- and there the
    # generated decoder read the bare array as an empty page and returned it
    # with a 200. A wrong answer is worse than an exception, so a body that
    # is not a page is a loud failure.
    #
    # An absent, null or empty `nextCursor` is still a valid page: it means
    # this was the last one. Only the `items` array is required.
    def coerce(raw)
      return raw if raw.is_a?(Hash) && raw["items"].is_a?(Array)

      raise Error.new(
        "Chatly: expected a cursor page -- an object with an \"items\" array -- but got " \
        "#{Page.describe(raw)}. If the route is not paginated, call the single-shot " \
        "method rather than its auto_* walker.",
        code: "sdk_not_a_page",
        body: raw.inspect[0, 500]
      )
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
