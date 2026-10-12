# frozen_string_literal: true

require_relative "test_helper"

# CONTRACT.md §10.6 -- "The auto-paginator walks two pages and stops on a
# null cursor" -- plus §5's second requirement, which is the one that bites:
# "it must not spin forever when the server repeats a cursor."
class PaginationTest < ChatlyTest
  def two_pages
    FakeTransport.new(
      FakeTransport.page([{ "id" => "c_1" }, { "id" => "c_2" }], "cursor_2"),
      FakeTransport.page([{ "id" => "c_3" }], nil)
    )
  end

  def test_auto_paginator_walks_two_pages_and_stops_on_a_null_cursor
    transport = two_pages
    ids = build_client(transport: transport).contacts.auto_list.map { |c| c["id"] }

    assert_equal %w[c_1 c_2 c_3], ids
    assert_equal 2, transport.requests.length, "it must stop, not ask for a third page"
    assert_nil query_of(transport.requests[0])
    assert_equal "cursor=cursor_2", query_of(transport.requests[1])
  end

  def test_the_first_pages_query_is_carried_onto_every_page
    transport = two_pages
    build_client(transport: transport).contacts.auto_list(limit: 2, filter: "status:open").to_a

    assert_equal "limit=2&filter=status%3Aopen", query_of(transport.requests[0])
    assert_equal "limit=2&filter=status%3Aopen&cursor=cursor_2", query_of(transport.requests[1])
  end

  # The failure mode this guard exists for: a server that echoes the cursor
  # it was handed. Without the seen-set this re-yields page two forever,
  # never raises, and looks like a hung job.
  def test_a_repeated_cursor_ends_the_walk_instead_of_spinning_forever
    transport = FakeTransport.new do |_request, n|
      raise "looped #{n} times -- a repeated cursor was not detected" if n > 5

      FakeTransport.page([{ "id" => "c_#{n}" }], "same_cursor")
    end
    ids = build_client(transport: transport).contacts.auto_list.map { |c| c["id"] }

    # Page 1 yields, we follow `same_cursor` once, page 2 yields, and the
    # second sighting of `same_cursor` ends it.
    assert_equal %w[c_1 c_2], ids
    assert_equal 2, transport.requests.length
  end

  def test_a_cursor_that_echoes_the_one_we_sent_ends_the_walk
    # Bounded on purpose. Without the limit, a regression in the seen-set
    # makes this test HANG instead of fail, and a hanging suite is a worse
    # signal than a red one -- it looks like a slow machine.
    transport = FakeTransport.new do |_request, n|
      raise "looped #{n} times -- the cursor we sent was not remembered" if n > 5

      FakeTransport.page([{ "id" => "only" }], "start_here")
    end
    items = build_client(transport: transport).contacts.auto_list(cursor: "start_here").to_a

    assert_equal 1, items.length
    assert_equal 1, transport.requests.length
  end

  def test_an_empty_string_cursor_is_treated_as_the_end
    transport = FakeTransport.new(FakeTransport.page([{ "id" => "c_1" }], ""))
    items = build_client(transport: transport).contacts.auto_list.to_a

    assert_equal 1, items.length
    assert_equal 1, transport.requests.length
  end

  def test_an_absent_cursor_key_is_treated_as_the_end
    transport = FakeTransport.new(FakeTransport.json(200, { "items" => [{ "id" => "c_1" }] }))

    assert_equal 1, build_client(transport: transport).contacts.auto_list.to_a.length
  end

  # The Ruby idiom the contract asks for: an Enumerator, so `lazy`,
  # `first(n)` and `each` all work -- and `first` must not fetch pages it
  # does not need.
  def test_it_returns_an_enumerator_that_is_lazy
    transport = two_pages
    enum = build_client(transport: transport).contacts.auto_list

    assert_kind_of Enumerator, enum
    assert_equal 0, transport.requests.length, "nothing is fetched until it is consumed"

    assert_equal %w[c_1 c_2], enum.first(2).map { |c| c["id"] }
    assert_equal 1, transport.requests.length, "first(2) must not fetch page two"
  end

  def test_lazy_chains_work
    transport = two_pages
    result = build_client(transport: transport)
             .contacts.auto_list.lazy.map { |c| c["id"] }.select { |id| id > "c_1" }.first(2)

    assert_equal %w[c_2 c_3], result
  end

  def test_a_single_page_is_available_unwalked
    transport = FakeTransport.new(FakeTransport.page([{ "id" => "c_1" }], "cursor_2"))
    page = build_client(transport: transport).contacts.list(limit: 1)

    assert_kind_of Chatly::Page, page
    assert_equal 1, page.size
    assert_equal "cursor_2", page.next_cursor
    assert_predicate page, :more?
    assert_equal({ "items" => [{ "id" => "c_1" }], "nextCursor" => "cursor_2" }, page.raw)
    # A Page is Enumerable over its own items, so the common case of
    # "process one page" needs no extra accessor.
    assert_equal ["c_1"], page.map { |c| c["id"] }
  end

  # `GET /v1/macros` is pagination-exempt and answers with a bare array,
  # while surface.json marks it paged. Treating an array as one cursorless
  # page is what keeps `list` and `auto_list` honest for that endpoint
  # instead of silently reporting zero rows.
  def test_a_bare_array_response_is_one_cursorless_page
    transport = FakeTransport.new(FakeTransport.json(200, [{ "id" => "m_1" }, { "id" => "m_2" }]))
    page = build_client(transport: transport).macros.list

    assert_equal 2, page.size
    assert_nil page.next_cursor
    refute_predicate page, :more?
  end

  def test_auto_list_over_a_bare_array_yields_everything_once
    transport = FakeTransport.new(FakeTransport.json(200, [{ "id" => "m_1" }]))
    ids = build_client(transport: transport).macros.auto_list.map { |m| m["id"] }

    assert_equal ["m_1"], ids
    assert_equal 1, transport.requests.length
  end

  def test_messages_paginate_under_a_conversation
    transport = FakeTransport.new(
      FakeTransport.page([{ "id" => "m_1" }], "c2"),
      FakeTransport.page([{ "id" => "m_2" }], nil)
    )
    ids = build_client(transport: transport).conversations.auto_messages("conv_1").map { |m| m["id"] }

    assert_equal %w[m_1 m_2], ids
    assert_equal "/v1/conversations/conv_1/messages", path_of(transport.requests[0])
  end

  # Every paged namespace offers the pair. A missing `auto_*` is the kind of
  # omission that is only noticed by the person who needed it.
  def test_every_paged_endpoint_has_an_auto_variant
    client = build_client(transport: FakeTransport.new)
    expected = {
      contacts: %i[list auto_list],
      conversations: %i[list auto_list messages auto_messages],
      tickets: %i[list auto_list],
      macros: %i[list auto_list],
      kb: %i[articles auto_articles],
      events: %i[list auto_list],
      webhooks: %i[deliveries auto_deliveries]
    }
    expected.each do |namespace, methods|
      methods.each do |method|
        assert_respond_to client.public_send(namespace), method
      end
    end
  end

  def test_string_and_symbol_query_keys_do_not_produce_two_cursor_parameters
    transport = FakeTransport.new(
      FakeTransport.page([{ "id" => "c_1" }], "next"),
      FakeTransport.page([], nil)
    )
    build_client(transport: transport).contacts.auto_list("cursor" => "first").to_a

    assert_equal "cursor=first", query_of(transport.requests[0])
    assert_equal "cursor=next", query_of(transport.requests[1])
  end

  def test_each_page_walks_page_boundaries
    transport = two_pages
    sizes = Chatly::Pagination.each_page({}) do |q|
      build_client(transport: transport).contacts.list(q)
    end.map(&:size)

    assert_equal [2, 1], sizes
  end
end
