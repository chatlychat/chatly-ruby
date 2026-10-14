# frozen_string_literal: true

require_relative "test_helper"

# Does the gem we would PUBLISH actually contain the gem we wrote?
#
# `chatly.gemspec` lists `spec.files` explicitly rather than globbing, for
# good reasons written down beside the list -- but the cost is that a new
# file can be forgotten, and the failure mode is the worst available:
# `lib/chatly.rb` requires every resource by name with `require_relative`,
# so ONE missing row makes `require "chatly"` raise LoadError for every
# customer who installs the gem, while every test in this repository passes.
# Nothing in the monorepo loads the gemspec's file list.
#
# Eleven files were one edit away from that when this SDK went from 55 typed
# methods to 159. So this compares the list against the directory, in both
# directions: a file on disk and not in the gemspec would not ship, and a
# file in the gemspec and not on disk fails `gem build`.
class PackagingTest < ChatlyTest
  ROOT = File.expand_path("..", __dir__)

  def gemspec_files
    # Evaluated rather than parsed: `spec.files` is Ruby, and a regex over
    # the source would not survive someone switching to a `.map` or a
    # constant. `Gem::Specification.load` is what RubyGems itself calls.
    spec = Gem::Specification.load(File.join(ROOT, "chatly.gemspec"))
    refute_nil spec, "chatly.gemspec did not load"
    spec.files
  end

  def test_every_library_file_on_disk_is_packaged
    on_disk = Dir.glob("lib/**/*.rb", base: ROOT).sort

    assert_operator on_disk.length, :>=, 20,
                    "the lib glob found #{on_disk.length} files -- it has stopped matching"
    missing = on_disk - gemspec_files

    assert_empty missing,
                 "these files exist and chatly.gemspec does not ship them, so " \
                 "`require \"chatly\"` would LoadError in the published gem"
  end

  def test_every_packaged_file_exists
    absent = gemspec_files.reject { |path| File.exist?(File.join(ROOT, path)) }

    assert_empty absent, "chatly.gemspec lists files that are not here; `gem build` would fail"
  end

  # The requires in `lib/chatly.rb` and the resource files are two lists that
  # have to agree, and neither is derived from the other -- the file is
  # deliberately not a `Dir.glob` (see its own comment). A resource that is
  # never required is a NameError the first time someone touches that
  # namespace.
  def test_every_resource_file_is_required_by_the_entry_point
    entry = File.read(File.join(ROOT, "lib/chatly.rb"))
    resources = Dir.glob("lib/chatly/resources/*.rb", base: ROOT)
                   .map { |path| File.basename(path, ".rb") }
                   .sort

    unrequired = resources.reject { |name| entry.include?(%(require_relative "chatly/resources/#{name}")) }

    assert_empty unrequired, "lib/chatly.rb does not require these resource files"
  end

  # And every required resource is reachable as a namespace on the client,
  # which is the only reason a resource file exists. A class that is loaded
  # but not in `NAMESPACES` is dead code that reads as a feature.
  def test_every_resource_class_is_a_client_namespace
    wired = Chatly::Client::NAMESPACES.values
    declared = Chatly::Resources.constants
                                .map { |name| Chatly::Resources.const_get(name) }
                                .select { |const| const.is_a?(Class) && const < Chatly::Resources::Base }

    assert_equal declared.sort_by(&:name), wired.sort_by(&:name),
                 "a resource class is not reachable from Chatly::Client"
  end
end
