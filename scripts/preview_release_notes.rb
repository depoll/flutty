# frozen_string_literal: true

module PreviewReleaseNotes
  module_function

  def current
    pr_number = normalize(ENV['FLUTTY_PR_NUMBER'])
    pr_title = normalize(ENV['FLUTTY_PR_TITLE'])
    return nil if pr_number.nil? && pr_title.nil?

    build_name = normalize(ENV['FLUTTY_BUILD_NAME'])
    version_codename = normalize(ENV['FLUTTY_VERSION_CODENAME'])
    source_sha = normalize(ENV['FLUTTY_SOURCE_SHA'])
    repository = normalize(ENV['GITHUB_REPOSITORY'])
    server_url = normalize(ENV['GITHUB_SERVER_URL']) || 'https://github.com'

    lines = [headline(pr_number: pr_number, pr_title: pr_title)]
    version_line = format_version(build_name: build_name, version_codename: version_codename)
    lines << version_line if version_line

    if repository && pr_number
      lines << "PR: #{server_url}/#{repository}/pull/#{pr_number}"
    end

    lines << "Commit: #{source_sha[0, 7]}" if source_sha

    lines.join("\n")
  end

  def headline(pr_number:, pr_title:)
    return "PR ##{pr_number}: #{pr_title}" if pr_number && pr_title
    return "PR ##{pr_number}" if pr_number

    pr_title
  end

  def format_version(build_name:, version_codename:)
    return nil if build_name.nil? && version_codename.nil?
    return %(Version: #{build_name} "#{version_codename}") if build_name && version_codename
    return "Version: #{build_name}" if build_name

    "Codename: #{version_codename}"
  end

  def normalize(value)
    trimmed = value.to_s.strip
    trimmed.empty? ? nil : trimmed
  end
end
