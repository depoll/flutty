# frozen_string_literal: true

module AppStorePatchVersion
  class ResolutionError < StandardError; end

  EDITABLE_STATES = %w[
    PREPARE_FOR_SUBMISSION
    DEVELOPER_REJECTED
    REJECTED
    METADATA_REJECTED
    WAITING_FOR_REVIEW
    INVALID_BINARY
  ].freeze

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

    editable_versions = parsed_versions.select do |_version, state|
      EDITABLE_STATES.include?(state)
    end
    editable = editable_versions
               .map(&:first)
               .max_by { |version| [version.major, version.minor, version.patch] }
    if editable && !same_version_line?(editable, base)
      raise ResolutionError,
            "Editable App Store version #{editable} does not match " \
            "the requested #{base.major}.#{base.minor}.x version line"
    end

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

  versions = app.get_app_store_versions(
    filter: { platform: Spaceship::ConnectAPI::Platform::IOS },
    includes: nil,
  ).map do |version|
    {
      version: version.version_string,
      state: version.app_version_state,
    }
  end

  resolved_version = AppStorePatchVersion.resolve(
    base_version: base_version,
    app_store_versions: versions,
  )
  File.write(output_path, "#{resolved_version}\n")
  puts "Resolved internal release marketing version #{resolved_version}"
end
