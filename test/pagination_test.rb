# frozen_string_literal: true

require_relative "test_helper"
require "set"

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

  # `GET /v1/macros` is `@PaginationExempt` and answers with a bare array, so
  # the method hands back the Array. It is deliberately NOT wrapped in a
  # `Chatly::Page`: a page object over a cursorless list advertises a
  # `next_cursor` the server never offered, and callers write paging loops
  # against it that can never terminate correctly.
  def test_macros_list_returns_the_bare_array_as_is
    transport = FakeTransport.new(FakeTransport.json(200, [{ "id" => "m_1" }, { "id" => "m_2" }]))
    result = build_client(transport: transport).macros.list

    assert_kind_of Array, result
    refute_kind_of Chatly::Page, result
    assert_equal %w[m_1 m_2], result.map { |m| m["id"] }
  end

  def test_macros_has_no_auto_paginator
    client = build_client(transport: FakeTransport.new)

    refute_respond_to client.macros, :auto_list,
                      "there is no cursor on GET /v1/macros, so there is nothing to walk"
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

  MANIFEST_PATH = File.expand_path("../../sdk-spec/surface.json", __dir__)

  # The manifest's `paged` entry => the `auto_*` method that walks it.
  AUTO_FOR = {
    %w[contacts list] => :auto_list,
    %w[conversations list] => :auto_list,
    %w[conversations messages] => :auto_messages,
    %w[tickets list] => :auto_list,
    %w[kb articles] => :auto_articles,
    %w[events list] => :auto_list,
    %w[webhooks deliveries] => :auto_deliveries
  }.freeze

  # Floor, not a discovery: if the manifest's `paged` set shrinks because
  # rows stopped parsing, this fails instead of quietly auditing less.
  #
  # It moved from 8 to 7 on 2026-10-12, and the reason matters: `macros.list`
  # was removed from the paged set because its route is `@PaginationExempt`
  # and returns a bare array -- not because the spec stopped parsing. Lower
  # it again only with the same kind of reason written down.
  PAGED_FLOOR = 7

  # Every paged endpoint offers the pair, and nothing else offers an `auto_*`.
  # A missing `auto_*` is the kind of omission only the person who needed it
  # notices; a SPURIOUS one is a paging loop over a route with no cursor.
  def test_every_paged_manifest_entry_has_an_auto_variant
    skip "packages/sdk-spec/surface.json not reachable from here" unless File.exist?(MANIFEST_PATH)

    entries = JSON.parse(File.read(MANIFEST_PATH)).fetch("entries")
    paged = entries.select { |e| e["paged"] }.map { |e| [e.fetch("ns"), e.fetch("name")] }

    assert_operator paged.length, :>=, PAGED_FLOOR,
                    "the manifest's paged set is below the floor of #{PAGED_FLOOR} -- " \
                    "either a row stopped parsing, or an endpoint genuinely stopped " \
                    "paginating and the floor moves in the same change"
    assert_equal AUTO_FOR.keys.sort, paged.sort,
                 "the manifest's paged set and this SDK's auto-paginators disagree"

    client = build_client(transport: FakeTransport.new)
    AUTO_FOR.each do |(ns, name), auto|
      namespace = client.public_send(ns)

      assert_respond_to namespace, name
      assert_respond_to namespace, auto
    end
  end

  def test_no_unpaged_namespace_offers_an_auto_paginator
    client = build_client(transport: FakeTransport.new)
    allowed = AUTO_FOR.map { |(ns, _name), auto| [ns.to_sym, auto] }.to_set

    Chatly::Client::NAMESPACES.each_key do |ns|
      namespace = client.public_send(ns)
      namespace.public_methods(false).grep(/\Aauto_/).each do |method|
        assert_includes allowed, [ns, method],
                        "#{ns}.#{method} walks a cursor the manifest does not declare"
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
