# frozen_string_literal: true

require 'open3'

# Fastlane 2.238.0 logs and swallows Git push failures. Check the local
# tracking ref after its push so an unpersisted profile cannot report success.
module MatchGitPersistence
  def self.verify!(directory, branch)
    status, status_result = Open3.capture2('git', 'status', '--porcelain', chdir: directory)
    ahead, ahead_result = Open3.capture2('git', 'rev-list', '--count',
                                       "refs/remotes/origin/#{branch}..HEAD", chdir: directory)
    return if status_result.success? && status.empty? && ahead_result.success? && ahead.strip == '0'

    raise 'Signing profiles were not persisted to the match repository. Check its write credentials and rerun profile regeneration.'
  end

  def git_push(...)
    super
    MatchGitPersistence.verify!(working_directory, branch)
  end

  private :git_push
end
