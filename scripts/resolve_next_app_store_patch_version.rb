# frozen_string_literal: true

module AppStorePatchVersion
  class ResolutionError < StandardError; end

  STORE_LISTING_EDITABLE_STATES = %w[
    PREPARE_FOR_SUBMISSION
    READY_FOR_REVIEW
    DEVELOPER_REJECTED
    REJECTED
    METADATA_REJECTED
    INVALID_BINARY
  ].freeze

  REVIEW_CANCELLATION_TIMEOUT_SECONDS = 900
  VERSION_PREPARATION_TIMEOUT_SECONDS = 120
  POLL_INTERVAL_SECONDS = 10

  Version = Struct.new(:major, :minor, :patch) do
    def to_s
      "#{major}.#{minor}.#{patch}"
    end
  end

  module_function

  def resolve(base_version:, app_store_versions:)
    base = parse!(base_version, label: 'base version')
    parsed_versions = app_store_versions.each_with_object([]) do |entry, result|
      version = parse(entry.fetch(:version))
      next if version.nil?

      result << [version, entry.fetch(:state)]
    end

    newer_version = parsed_versions.map(&:first).find do |version|
      version.major > base.major ||
        (version.major == base.major && version.minor > base.minor)
    end
    if newer_version
      raise ResolutionError,
            "App Store version #{newer_version} does not match " \
            "the requested #{base.major}.#{base.minor}.x version line"
    end

    editable_versions = parsed_versions.select do |_version, state|
      STORE_LISTING_EDITABLE_STATES.include?(state)
    end
    editable = editable_versions
               .map(&:first)
               .select { |version| same_version_line?(version, base) }
               .max_by(&:patch)
    return editable.to_s if editable && editable.patch >= base.patch

    existing_patches = parsed_versions
                       .map(&:first)
                       .select { |version| same_version_line?(version, base) }
                       .map(&:patch)
    next_patch = if existing_patches.empty?
                   base.patch
                 else
                   [base.patch, existing_patches.max + 1].max
                 end

    Version.new(base.major, base.minor, next_patch).to_s
  end

  def parse(value)
    match = /\A(\d+)\.(\d+)\.(\d+)\z/.match(value.to_s.strip)
    return if match.nil?

    Version.new(*match.captures.map(&:to_i))
  end

  def parse!(value, label:)
    parse(value) || raise(
      ResolutionError,
      "#{label.capitalize} must use numeric x.y.z format; received #{value.inspect}",
    )
  end

  def same_version_line?(left, right)
    left.major == right.major && left.minor == right.minor
  end

  def store_listing_editable?(state)
    STORE_LISTING_EDITABLE_STATES.include?(state)
  end
end

if $PROGRAM_NAME == __FILE__
  require 'spaceship'

  base_version, bundle_id, output_path = ARGV
  if [base_version, bundle_id, output_path].any? { |value| value.to_s.empty? }
    warn 'Usage: resolve_next_app_store_patch_version.rb BASE_VERSION BUNDLE_ID OUTPUT_PATH'
    exit 2
  end

  token = Spaceship::ConnectAPI::Token.create(
    key_id: ENV.fetch('APP_STORE_CONNECT_API_KEY_ID'),
    issuer_id: ENV.fetch('APP_STORE_CONNECT_API_ISSUER_ID'),
    key: ENV.fetch('APP_STORE_CONNECT_API_KEY_CONTENT'),
  )
  Spaceship::ConnectAPI.token = token

  app = Spaceship::ConnectAPI::App.find(bundle_id)
  raise AppStorePatchVersion::ResolutionError, "App #{bundle_id} was not found" if app.nil?

  platform = Spaceship::ConnectAPI::Platform::IOS
  app_store_versions = app.get_app_store_versions(
    filter: { platform: platform },
    includes: nil,
  )
  versions = app_store_versions.map do |version|
    {
      version: version.version_string,
      state: version.app_version_state,
    }
  end

  resolved_version = AppStorePatchVersion.resolve(
    base_version: base_version,
    app_store_versions: versions,
  )
  unless versions.any? { |version| version[:version] == resolved_version }
    submission = app.get_in_progress_review_submission(
      platform: platform,
      includes: 'appStoreVersionForReview',
    )
    version_to_advance = nil
    if submission
      version_to_advance = submission.app_store_version_for_review
      if version_to_advance.nil?
        raise AppStorePatchVersion::ResolutionError,
              'Active App Store review did not include its app version'
      end

      puts 'Canceling the current App Store review before advancing the patch version'
      submission.cancel_submission

      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) +
                 AppStorePatchVersion::REVIEW_CANCELLATION_TIMEOUT_SECONDS
      loop do
        active_submission = app.get_in_progress_review_submission(
          platform: platform,
        )
        version_to_advance = Spaceship::ConnectAPI::AppStoreVersion.get(
          app_store_version_id: version_to_advance.id,
          includes: nil,
        )
        if version_to_advance.nil?
          raise AppStorePatchVersion::ResolutionError,
                'App Store version disappeared during review cancellation'
        end
        unlocked = AppStorePatchVersion.store_listing_editable?(
          version_to_advance.app_version_state,
        )
        break if active_submission.nil? && unlocked

        if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          raise AppStorePatchVersion::ResolutionError,
                'Timed out waiting for App Store review cancellation; ' \
                "version state is #{version_to_advance.app_version_state}"
        end

        sleep AppStorePatchVersion::POLL_INTERVAL_SECONDS
      end
      puts 'App Store review cancellation completed'
    else
      base = AppStorePatchVersion.parse!(base_version, label: 'base version')
      editable_versions = app_store_versions.select do |version|
        parsed = AppStorePatchVersion.parse(version.version_string)
        parsed &&
          AppStorePatchVersion.same_version_line?(parsed, base) &&
          AppStorePatchVersion.store_listing_editable?(
            version.app_version_state,
          )
      end
      version_to_advance = editable_versions.max_by do |version|
        AppStorePatchVersion.parse(version.version_string).patch
      end
    end

    if version_to_advance
      version_to_advance.update(
        attributes: { version_string: resolved_version },
      )
    else
      Spaceship::ConnectAPI.post_app_store_version(
        app_id: app.id,
        attributes: {
          versionString: resolved_version,
          platform: platform,
        },
      )
    end

    preparation_deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) +
                           AppStorePatchVersion::VERSION_PREPARATION_TIMEOUT_SECONDS
    loop do
      prepared_version = app.get_app_store_versions(
        filter: { platform: platform },
        includes: nil,
      ).find { |version| version.version_string == resolved_version }
      prepared = prepared_version &&
                 AppStorePatchVersion.store_listing_editable?(
                   prepared_version.app_version_state,
                 )
      break if prepared

      if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= preparation_deadline
        raise AppStorePatchVersion::ResolutionError,
              "Timed out preparing editable App Store version #{resolved_version}"
      end

      sleep AppStorePatchVersion::POLL_INTERVAL_SECONDS
    end
    puts "Prepared editable App Store version #{resolved_version}"
  end

  File.write(output_path, "#{resolved_version}\n")
  puts "Resolved internal release marketing version #{resolved_version}"
end
