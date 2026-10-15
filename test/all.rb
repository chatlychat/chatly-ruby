# frozen_string_literal: true

# The whole suite, in one command, with no bundler and no gems:
#
#   ruby -Ilib -Itest test/all.rb
#
# Listed explicitly rather than globbed. A glob runs whatever happens to be
# in the directory, so a file that fails to load for an unrelated reason can
# drop out of the run while the summary still says "0 failures" -- the suite
# reports the number of tests it managed to find, not the number that exist.
# This list is the number that exist, and `test_every_test_file_is_listed`
# below fails if the two ever disagree.
TEST_FILES = %w[
  client_test
  errors_test
  identity_test
  loopback_test
  packaging_test
  pagination_test
  retries_test
  rotate_external_secret_test
  signatures_test
  surface_lock_test
  surface_test
  webhooks_test
  wire_bodies_test
].freeze

TEST_FILES.each { |file| require_relative file }

class SuiteCompletenessTest < Minitest::Test
  def test_every_test_file_is_listed
    on_disk = Dir.children(__dir__)
                 .grep(/_test\.rb\z/)
                 .map { |name| name.sub(/\.rb\z/, "") }
                 .sort

    assert_equal TEST_FILES.sort, on_disk,
                 "a test file exists that test/all.rb does not run"
  end
end
