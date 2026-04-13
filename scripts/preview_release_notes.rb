# frozen_string_literal: true

module PreviewReleaseNotes
  module_function

  def current(max_length: nil)
    pr_number = normalize(ENV['FLUTTY_PR_NUMBER'])
    pr_title = normalize(ENV['FLUTTY_PR_TITLE'])
    return nil if pr_number.nil? && pr_title.nil?

    build_name = normalize(ENV['FLUTTY_BUILD_NAME'])
    version_codename = normalize(ENV['FLUTTY_VERSION_CODENAME'])
    source_sha = normalize(ENV['FLUTTY_SOURCE_SHA'])
    repository = normalize(ENV['GITHUB_REPOSITORY'])
    server_url = normalize(ENV['GITHUB_SERVER_URL']) || 'https://github.com'
    pr_commits = normalize(ENV['FLUTTY_PR_COMMITS'])

    lines = [headline(pr_number: pr_number, pr_title: pr_title)]
    version_line = format_version(build_name: build_name, version_codename: version_codename)
    lines << version_line if version_line

    if repository && pr_number
      lines << "PR: #{server_url}/#{repository}/pull/#{pr_number}"
    end

    lines << "Commit: #{source_sha[0, 7]}" if source_sha

    header = lines.join("\n")

    append_commits(header, pr_commits, max_length: max_length)
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

  def append_commits(header, raw_commits, max_length:)
    return header if raw_commits.nil?

    commit_lines = raw_commits.split("\n").reject(&:empty?)
    return header if commit_lines.empty?

    result = "#{header}\n\nCommits:"
    included = 0

    commit_lines.each_with_index do |line, index|
      entry = "\n- #{line}"
      remaining = commit_lines.length - index - 1
      suffix = remaining.positive? ? "\n... and #{remaining} more" : ''

      candidate = result + entry
      if max_length.nil? || (candidate + suffix).length <= max_length
        result = candidate
        included += 1
      else
        break
      end
    end

    return header if included.zero?

    if included < commit_lines.length
      result += "\n... and #{commit_lines.length - included} more"
    end

    result
  end

  def normalize(value)
    trimmed = value.to_s.strip
    trimmed.empty? ? nil : trimmed
  end
end
