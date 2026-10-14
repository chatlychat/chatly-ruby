# frozen_string_literal: true

require_relative "test_helper"
require_relative "surface_lock_table"

# Parity evidence, produced by EXECUTING the client.
#
# `scripts/check-sdk-surface-parity.mjs` matches path strings in SDK source
# text, and its first version counted a doc comment that merely named a route
# as an implementation -- it printed 55/55 for methods that did not exist.
# Text matching cannot tell documentation from code, and it cannot see a path
# assembled through a helper either (this gem builds every path from a `PATH`
# constant plus a template, so the literal `/v1/contacts/{id}` appears in no
# source file).
#
# So this test calls all 162 methods against a fake transport, records the
# `METHOD /path` each one actually put on the wire, normalises the
# interpolated segments back to the manifest's `{...}` names by POSITION, and
# writes `surface.lock.json`. Then it asserts the lock equals the manifest.
#
# Running the suite regenerates the lock. That is deliberate: a lock
# refreshed by a separate script is a lock somebody forgets to refresh.
class SurfaceLockTest < ChatlyTest
  # EXPECTED_SHAPE, SHAPE_COUNTS and EXTRA_ARGS -- the hand-declared column
  # and the call arguments. In their own file since the surface reached 159
  # routes; read the comments there before changing a value.
  include SurfaceLockTable

  # Monorepo first, then the vendored copy a public mirror carries at its root
  # (a mirror has no `packages/` above the package).
  MANIFEST_PATH = [
    File.expand_path("../../sdk-spec/surface.json", __dir__),
    File.expand_path("../sdk-spec/surface.json", __dir__),
  ].find { |p| File.exist?(p) } || File.expand_path("../../sdk-spec/surface.json", __dir__)
  LOCK_PATH = File.expand_path("../surface.lock.json", __dir__)

  # `surface.json` name => the Ruby method, where they differ. `send` is the
  # only one, and it has to differ: `send` is `Object#send`.
  RUBY_NAMES = { "send" => "send_message" }.freeze

  def manifest
    @manifest ||= JSON.parse(File.read(MANIFEST_PATH))
  end

  # A sentinel per path position. Only characters this SDK's path escaper
  # leaves alone, so what comes back out of the URL is what went in and the
  # substitution below cannot silently miss.
  def sentinel(index)
    "ZZpathparamZZ#{index}ZZ"
  end

  def param_names(template)
    template.scan(/\{(\w+)\}/).flatten
  end

  # The shape a decoded value actually HAS, named in the same four words.
  #
  # Ruby-specific, and worth saying out loud: this gem does not normalise
  # keys. A decoded object keeps the server's camelCase exactly as sent (see
  # the README's "Shapes" note), so the envelope probe looks for `nextCursor`
  # and accepts `next_cursor` only because `Chatly::Page` itself accepts both
  # spellings. A paginated route in this SDK hands back a `Chatly::Page`
  # rather than the raw Hash, so that case is first.
  def actual_shape(value)
    case value
    when nil then "empty"
    when Chatly::Page then "page"
    when Array then "array"
    when Hash
      envelope = value.key?("nextCursor") || value.key?("next_cursor")
      value["items"].is_a?(Array) && envelope ? "page" : "object"
    else "scalar(#{value.class})"
    end
  end

  def declared_shape(ns, name)
    EXPECTED_SHAPE.fetch("#{ns}.#{name}") do
      raise "#{ns}.#{name} has no declared response shape -- add it to EXPECTED_SHAPE " \
            "by reading the handler, not by copying surface.json"
    end
  end

  # Call one manifest entry and return the normalised "METHOD /path".
  def observe(entry)
    ns = entry.fetch("ns")
    name = entry.fetch("name")
    template = entry.fetch("path")
    names = param_names(template)
    path_args = names.each_index.map { |i| sentinel(i) }
    extras = EXTRA_ARGS.fetch([ns, name], [])
    shape = declared_shape(ns, name)

    # The fake answers with the shape THIS FILE declares for THIS route --
    # not a page envelope for everything, and not the manifest's own `shape`
    # column either, which would make the comparison at the bottom circular.
    # Two sibling SDKs shipped a decode error on `GET /v1/macros` because
    # their fakes did the former, and their surface suites stayed green.
    transport = FakeTransport.new { |_r, _n| FakeTransport.for_shape(shape) }
    client = build_client(transport: transport)
    target = ns == "root" ? client : client.public_send(ns)
    ruby_name = RUBY_NAMES.fetch(name, name)
    result = target.public_send(ruby_name, *path_args, *extras)

    # The value handed back really has the declared shape. This is what
    # catches a method that wraps or unwraps -- a `list` that returned
    # `page.items`, or one that reached for `["items"]` on a bare-array route
    # -- even when the request it issued was perfect.
    assert_equal shape, actual_shape(result),
                 "#{ns}.#{ruby_name} was answered with a #{shape} body and handed back " \
                 "#{actual_shape(result)}"

    # And a page route hands back a Page while nothing else does, because a
    # Page over a cursorless route advertises a cursor that does not exist.
    if shape == "page"
      assert_kind_of Chatly::Page, result,
                     "#{ns}.#{ruby_name} answers with a page envelope and did not return a Page"
    else
      refute_kind_of Chatly::Page, result,
                     "#{ns}.#{ruby_name} is a #{shape} route but returned a Page"
    end

    assert_equal 1, transport.requests.length, "#{ns}.#{ruby_name} made #{transport.requests.length} requests"
    request = transport.requests.fetch(0)
    observed = URI.parse(request.url).path

    # Substitute by POSITION, using the manifest's own parameter names.
    names.each_with_index { |param, i| observed = observed.sub(sentinel(i), "{#{param}}") }

    refute_match(/ZZpathparamZZ/, observed,
                 "#{ns}.#{ruby_name} did not put every path argument in the path")
    # Key order is fixed across all eight locks: ns, name, http, path, shape.
    { "ns" => ns, "name" => name, "http" => request.method, "path" => observed,
      "shape" => shape }
  end

  # Generate the lock, once per process, and write it.
  #
  # Called by every test here rather than left to one of them, because
  # minitest randomises test order -- a test that depended on an earlier
  # test having written the file would fail on some seeds and pass on
  # others, which is the worst kind of red.
  def ensure_lock!
    @@lock ||= begin # rubocop:disable Style/ClassVars
      observed = manifest.fetch("entries").map { |entry| observe(entry) }
                         .sort_by { |e| [e.fetch("ns"), e.fetch("name")] }
      lock = {
        "sdk" => "ruby",
        "generatedBy" => "test/surface_lock_test.rb",
        "entries" => observed
      }
      File.write(LOCK_PATH, "#{JSON.pretty_generate(lock)}\n")
      lock
    end
  end

  # The manifest's own five columns, for the comparison. `shape` is included
  # here on purpose: this is the local half of what
  # `scripts/check-sdk-surface-parity.mjs` does across eight SDKs, and the
  # column on our side came from EXPECTED_SHAPE, read off the handlers.
  def expected_entries
    manifest.fetch("entries").map do |entry|
      row = entry.slice("ns", "name", "http", "path", "shape")
      unless FakeTransport::SHAPES.include?(row["shape"])
        raise "surface.json entry #{entry.fetch('ns')}.#{entry.fetch('name')} has no valid " \
              "`shape` (got #{row['shape'].inspect})"
      end
      row
    end.sort_by { |e| [e.fetch("ns"), e.fetch("name")] }
  end

  def test_the_lock_is_regenerated_and_equals_the_manifest
    skip "packages/sdk-spec/surface.json not reachable from here" unless File.exist?(MANIFEST_PATH)

    observed = ensure_lock!.fetch("entries")
    expected = expected_entries

    # Diffed field by field, because `assert_equal` on two 162-element arrays
    # of hashes prints something nobody can read.
    expected.zip(observed).each do |want, got|
      assert_equal want, got,
                   "#{want.fetch('ns')}.#{want.fetch('name')}: this SDK issues " \
                   "#{got&.fetch('http')} #{got&.fetch('path')}, the manifest says " \
                   "#{want.fetch('http')} #{want.fetch('path')}"
    end
    assert_equal expected, observed
    assert_equal manifest.fetch("entries").length, observed.length
  end

  # The FILE, re-read off disk: its shape, its sort order and its contents.
  #
  # Honest about what this does not do: it cannot catch a stale committed
  # lock, because `ensure_lock!` rewrites the file first. Staleness shows up
  # as a dirty working tree after running the suite -- that is the signal, and
  # it is why regeneration lives in the test rather than in a script.
  def test_the_lock_file_on_disk_has_the_right_shape_and_contents
    skip "packages/sdk-spec/surface.json not reachable from here" unless File.exist?(MANIFEST_PATH)

    ensure_lock!
    # Read it back off disk, so this checks the FILE and not the Hash that
    # produced it -- a serialisation that loses a field would otherwise pass.
    lock = JSON.parse(File.read(LOCK_PATH))

    assert_equal "ruby", lock.fetch("sdk")
    assert_equal "test/surface_lock_test.rb", lock.fetch("generatedBy")
    assert_equal %w[sdk generatedBy entries].sort, lock.keys.sort

    entries = lock.fetch("entries")

    assert_equal entries.sort_by { |e| [e.fetch("ns"), e.fetch("name")] }, entries,
                 "lock entries must be sorted by ns then name"
    entries.each do |e|
      # Order, not just presence: every lock on this surface is written
      # ns, name, http, path, shape, so the eight files diff against each
      # other by eye as well as by script.
      assert_equal %w[ns name http path shape], e.keys
      assert_includes %w[GET POST PUT PATCH DELETE], e.fetch("http")
      assert e.fetch("path").start_with?("/v1/"), "#{e.fetch('path')} is not a /v1 path"
      assert_includes FakeTransport::SHAPES, e.fetch("shape"),
                      "#{e.fetch('ns')}.#{e.fetch('name')} has no valid shape in the lock"
    end

    assert_equal expected_entries, entries
  end

  # The lock is only evidence if every row came from a real call. A manifest
  # row this SDK forgot would otherwise be missing from the lock AND from the
  # comparison, and the two would agree about 54 methods.
  def test_the_lock_covers_every_manifest_entry
    skip "packages/sdk-spec/surface.json not reachable from here" unless File.exist?(MANIFEST_PATH)

    assert_equal 162, manifest.fetch("entries").length,
                 "the manifest changed size -- re-read it before trusting this suite"

    pairs = ensure_lock!.fetch("entries").map { |e| [e.fetch("ns"), e.fetch("name")] }

    manifest.fetch("entries").each do |entry|
      assert_includes pairs, [entry.fetch("ns"), entry.fetch("name")]
    end
    assert_equal pairs.length, pairs.uniq.length, "the lock has a duplicate entry"
  end
  # Anti-vacuity for the declared column.
  #
  # Every other assertion in this file would be satisfied by a column that
  # said "object" 162 times: the fake would answer every route with an object,
  # every decoder would hand one back, and the lock would be internally
  # consistent and useless. So the DISTRIBUTION is asserted, and it runs even
  # when the manifest is out of reach (inside an installed gem) because it
  # depends on nothing but this file.
  #
  # If the surface grows, these numbers move in the same change as the new
  # rows -- but all four shapes must stay represented, and `empty` stays at
  # exactly one until a second real 204 genuinely ships.
  def test_the_declared_shape_column_is_complete_and_not_vacuous
    assert_equal 162, EXPECTED_SHAPE.length, "a route lost its declared shape"

    EXPECTED_SHAPE.each do |key, shape|
      assert_includes FakeTransport::SHAPES, shape,
                      "#{key} declares #{shape.inspect}, which is not one of the four shapes"
    end

    assert_equal SHAPE_COUNTS, EXPECTED_SHAPE.values.tally,
                 "the declared shapes no longer match the handlers they were read from -- " \
                 "if that is deliberate, move SHAPE_COUNTS in the same change and say why"
  end

  def test_the_declared_shapes_cover_exactly_the_manifest_routes
    skip "packages/sdk-spec/surface.json not reachable from here" unless File.exist?(MANIFEST_PATH)

    keys = manifest.fetch("entries").map { |e| "#{e.fetch('ns')}.#{e.fetch('name')}" }

    assert_equal keys.sort, EXPECTED_SHAPE.keys.sort,
                 "EXPECTED_SHAPE and surface.json disagree about which routes exist"
  end

  # One walker per route declared `page`, keyed the manifest's way so the set
  # can be compared with the declaration rather than trusted.
  def walkers(client)
    {
      "bots.deliveries" => -> { client.bots.auto_deliveries("bot_1") },
      "bots.list" => -> { client.bots.auto_list },
      "contacts.journey" => -> { client.contacts.auto_journey("c_1") },
      "contacts.list" => -> { client.contacts.auto_list },
      "conversations.list" => -> { client.conversations.auto_list },
      "conversations.messages" => -> { client.conversations.auto_messages("v_1") },
      "conversations.unattended" => -> { client.conversations.auto_unattended },
      "events.list" => -> { client.events.auto_list },
      "kb.articles" => -> { client.kb.auto_articles },
      "search.query" => -> { client.search.auto_query("a search term") },
      "tickets.list" => -> { client.tickets.auto_list },
      "triggers.list" => -> { client.triggers.auto_list },
      "webhooks.deliveries" => -> { client.webhooks.auto_deliveries }
    }
  end

  # The negative direction: a paginator fed the WRONG shape must fail loudly.
  #
  # The lock test above proves each method copes with the shape this file says
  # its route sends. It cannot prove the declaration MATTERS -- a decoder that
  # ignored the body entirely would sail through it. So this feeds every
  # auto-paginator a bare array where it expects `{ items, nextCursor }` and
  # requires it to raise, which is exactly the failure the real API handed the
  # .NET and Rust clients on `macros.list`.
  #
  # `Chatly::Page` used to answer this case with an EMPTY page -- `hash =
  # raw.is_a?(Hash) ? raw : {}` -- so `auto_list` over a non-page body yielded
  # nothing and returned normally, which reads as "this workspace has no
  # contacts". It raises `sdk_not_a_page` now, and this test is what holds it
  # there.
  def test_every_auto_paginator_rejects_a_bare_array_where_a_page_is_expected
    paged = EXPECTED_SHAPE.select { |_key, shape| shape == "page" }.keys

    assert_equal 13, paged.length, "the page set changed size -- re-read the handlers"

    client = build_client(
      transport: FakeTransport.new { |_r, _n| FakeTransport.for_shape("array") }
    )
    walks = walkers(client)

    # The floor that stops this test quietly shrinking: exactly the routes
    # declared `page`, no more and no fewer.
    assert_equal paged.sort, walks.keys.sort,
                 "the walkers exercised here and the routes declared `page` disagree"

    walks.each do |key, walk|
      error = assert_raises(Chatly::Error, "#{key} accepted a bare array as a page") do
        walk.call.first
      end

      assert_equal "sdk_not_a_page", error.code,
                   "#{key} failed on a bare array, but not with the page-shape error"
    end

    # The single-shot sibling too: `contacts.list` wraps one page, and it has
    # the same obligation as the walker over it.
    error = assert_raises(Chatly::Error) { client.contacts.list }

    assert_equal "sdk_not_a_page", error.code
  end
end
