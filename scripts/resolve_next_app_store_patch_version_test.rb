# frozen_string_literal: true

require 'minitest/autorun'
require_relative 'resolve_next_app_store_patch_version'

class AppStorePatchVersionTest < Minitest::Test
  def test_increments_the_latest_used_patch
    assert_equal(
      '0.2.3',
      resolve(
        '0.2.0',
        [
          version('0.2.0', 'READY_FOR_DISTRIBUTION'),
          version('0.2.2', 'REPLACED_WITH_NEW_VERSION'),
        ],
      ),
    )
  end

  def test_reuses_the_current_editable_patch
    assert_equal(
      '0.2.1',
      resolve(
        '0.2.0',
        [
          version('0.1.9', 'REJECTED'),
          version('0.2.0', 'READY_FOR_DISTRIBUTION'),
          version('0.2.1', 'PREPARE_FOR_SUBMISSION'),
        ],
      ),
    )
  end

  def test_advances_past_the_current_patch_during_review
    assert_equal(
      '0.2.2',
      resolve(
        '0.2.0',
        [
          version('0.2.0', 'READY_FOR_DISTRIBUTION'),
          version('0.2.1', 'IN_REVIEW'),
        ],
      ),
    )
  end

  def test_advances_past_the_current_patch_waiting_for_review
    assert_equal(
      '0.2.2',
      resolve(
        '0.2.0',
        [
          version('0.2.0', 'READY_FOR_DISTRIBUTION'),
          version('0.2.1', 'WAITING_FOR_REVIEW'),
        ],
      ),
    )
  end

  def test_uses_the_base_patch_as_a_floor
    assert_equal(
      '0.2.5',
      resolve(
        '0.2.5',
        [version('0.2.0', 'READY_FOR_DISTRIBUTION')],
      ),
    )
  end

  def test_keeps_a_new_major_minor_version_line_at_its_base_patch
    assert_equal(
      '0.3.0',
      resolve(
        '0.3.0',
        [version('0.2.9', 'READY_FOR_DISTRIBUTION')],
      ),
    )
  end

  def test_ignores_a_stale_editable_version_from_an_older_version_line
    assert_equal(
      '0.2.1',
      resolve(
        '0.2.0',
        [
          version('0.1.9', 'REJECTED'),
          version('0.2.0', 'READY_FOR_DISTRIBUTION'),
        ],
      ),
    )
  end

  def test_rejects_an_editable_version_from_a_newer_version_line
    error = assert_raises(AppStorePatchVersion::ResolutionError) do
      resolve(
        '0.2.0',
        [version('0.3.0', 'PREPARE_FOR_SUBMISSION')],
      )
    end

    assert_includes(error.message, 'does not match the requested 0.2.x')
  end

  def test_rejects_a_locked_version_from_a_newer_version_line
    error = assert_raises(AppStorePatchVersion::ResolutionError) do
      resolve(
        '0.2.0',
        [version('0.3.0', 'WAITING_FOR_REVIEW')],
      )
    end

    assert_includes(error.message, 'does not match the requested 0.2.x')
  end

  def test_rejects_a_non_numeric_base_version
    assert_raises(AppStorePatchVersion::ResolutionError) do
      resolve('0.2', [])
    end
  end

  def test_store_listing_is_editable_before_review_submission
    assert(AppStorePatchVersion.store_listing_editable?('PREPARE_FOR_SUBMISSION'))
    assert(AppStorePatchVersion.store_listing_editable?('READY_FOR_REVIEW'))
  end

  def test_store_listing_is_locked_after_review_submission
    refute(AppStorePatchVersion.store_listing_editable?('WAITING_FOR_REVIEW'))
    refute(AppStorePatchVersion.store_listing_editable?('IN_REVIEW'))
  end

  private

  def resolve(base_version, versions)
    AppStorePatchVersion.resolve(
      base_version: base_version,
      app_store_versions: versions,
    )
  end

  def version(value, state)
    { version: value, state: state }
  end
end
