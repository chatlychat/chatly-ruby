# frozen_string_literal: true

require_relative "test_helper"

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
# So this test calls all 55 methods against a fake transport, records the
# `METHOD /path` each one actually put on the wire, normalises the
# interpolated segments back to the manifest's `{...}` names by POSITION, and
# writes `surface.lock.json`. Then it asserts the lock equals the manifest.
#
# Running the suite regenerates the lock. That is deliberate: a lock
# refreshed by a separate script is a lock somebody forgets to refresh.
class SurfaceLockTest < ChatlyTest
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

  # Positional arguments a method needs BEYOND its path parameters, keyed by
  # the manifest's [ns, name]. A body, or a value the method accepts
  # positionally and puts in the body.
  #
  # Path parameters are not listed here -- they are generated from the
  # manifest's own template, which is what makes the normalisation below
  # honest rather than a restatement of the table.
  EXTRA_ARGS = {
    %w[contacts upsert] => [{ email: "a@example.com" }],
    %w[contacts bulk_upsert] => [[{ email: "a@example.com" }]],
    %w[contacts merge] => ["00000000-0000-7000-8000-000000000001"],
    %w[contacts add_tags] => ["vip"],
    %w[contacts unsubscribe] => [{}],
    %w[conversations send] => [{ body: "hello" }],
    %w[conversations set_agent_handling] => [{ state: "handled" }],
    %w[conversations generate_reply] => [{}],
    %w[conversations schedule_message] => [{ body: "later", sendAt: "2026-10-12T00:00:00Z" }],
    %w[tickets merge] => ["00000000-0000-7000-8000-000000000002"],
    %w[tickets split] => [{ title: "the other half" }],
    %w[tickets bulk] => [{ ids: ["00000000-0000-7000-8000-000000000003"], action: "status" }],
    %w[macros create] => [{ name: "n", scope: "workspace", body: "b" }],
    %w[macros update] => [{ name: "renamed" }],
    %w[search query] => ["a search term"],
    %w[events track] => [{ contactId: "00000000-0000-7000-8000-000000000004", name: "evt" }],
    %w[webhooks redeliver] => [{}]
  }.freeze

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

  # Call one manifest entry and return the normalised "METHOD /path".
  def observe(entry)
    ns = entry.fetch("ns")
    name = entry.fetch("name")
    template = entry.fetch("path")
    names = param_names(template)
    path_args = names.each_index.map { |i| sentinel(i) }
    extras = EXTRA_ARGS.fetch([ns, name], [])

    # The fake answers with the shape THIS route returns, taken from the
    # manifest entry -- not a page envelope for everything. Two sibling SDKs
    # shipped a decode error on `GET /v1/macros` because their fakes did the
    # latter, and their surface suites stayed green through it.
    transport = FakeTransport.new { |_r, _n| FakeTransport.for_entry(entry) }
    client = build_client(transport: transport)
    target = ns == "root" ? client : client.public_send(ns)
    ruby_name = RUBY_NAMES.fetch(name, name)
    result = target.public_send(ruby_name, *path_args, *extras)

    # A paged entry must hand back a Page; a non-paged one must not, because
    # a Page over a cursorless route advertises a cursor that does not exist.
    if entry["paged"]
      assert_kind_of Chatly::Page, result, "#{ns}.#{ruby_name} is paged and did not return a Page"
    else
      refute_kind_of Chatly::Page, result,
                     "#{ns}.#{ruby_name} is not paged in the manifest but returned a Page"
    end

    assert_equal 1, transport.requests.length, "#{ns}.#{ruby_name} made #{transport.requests.length} requests"
    request = transport.requests.fetch(0)
    observed = URI.parse(request.url).path

    # Substitute by POSITION, using the manifest's own parameter names.
    names.each_with_index { |param, i| observed = observed.sub(sentinel(i), "{#{param}}") }

    refute_match(/ZZpathparamZZ/, observed,
                 "#{ns}.#{ruby_name} did not put every path argument in the path")
    { "ns" => ns, "name" => name, "http" => request.method, "path" => observed }
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

  def expected_entries
    manifest.fetch("entries").map { |entry| entry.slice("ns", "name", "http", "path") }
            .sort_by { |e| [e.fetch("ns"), e.fetch("name")] }
  end

  def test_the_lock_is_regenerated_and_equals_the_manifest
    skip "packages/sdk-spec/surface.json not reachable from here" unless File.exist?(MANIFEST_PATH)

    observed = ensure_lock!.fetch("entries")
    expected = expected_entries

    # Diffed field by field, because `assert_equal` on two 55-element arrays
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
      assert_equal %w[http name ns path], e.keys.sort
      assert_includes %w[GET POST PUT PATCH DELETE], e.fetch("http")
      assert e.fetch("path").start_with?("/v1/"), "#{e.fetch('path')} is not a /v1 path"
    end

    assert_equal expected_entries, entries
  end

  # The lock is only evidence if every row came from a real call. A manifest
  # row this SDK forgot would otherwise be missing from the lock AND from the
  # comparison, and the two would agree about 54 methods.
  def test_the_lock_covers_every_manifest_entry
    skip "packages/sdk-spec/surface.json not reachable from here" unless File.exist?(MANIFEST_PATH)

    assert_equal 55, manifest.fetch("entries").length,
                 "the manifest changed size -- re-read it before trusting this suite"

    pairs = ensure_lock!.fetch("entries").map { |e| [e.fetch("ns"), e.fetch("name")] }

    manifest.fetch("entries").each do |entry|
      assert_includes pairs, [entry.fetch("ns"), entry.fetch("name")]
    end
    assert_equal pairs.length, pairs.uniq.length, "the lock has a duplicate entry"
  end
end
