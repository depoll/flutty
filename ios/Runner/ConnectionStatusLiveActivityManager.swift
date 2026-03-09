import ActivityKit
import Foundation

@available(iOS 16.1, *)
final class ConnectionStatusLiveActivityManager {
  static let shared = ConnectionStatusLiveActivityManager()

  private struct StatusPayload {
    let connectionCount: Int
    let connectedCount: Int
  }

  private var latestStatus: StatusPayload?
  private var isForeground = true

  private init() {}

  func updateStatus(
    connectionCount: Int,
    connectedCount: Int
  ) {
    latestStatus = StatusPayload(
      connectionCount: connectionCount,
      connectedCount: connectedCount
    )
    refreshPresentation()
  }

  func setForegroundState(isForeground: Bool) {
    self.isForeground = isForeground
    refreshPresentation()
  }

  func stop() {
    latestStatus = nil
    endActivities()
  }

  private func refreshPresentation() {
    guard #available(iOS 16.1, *) else {
      return
    }

    guard let latestStatus, latestStatus.connectionCount > 0 else {
      endActivities()
      return
    }

    let canStartNewActivity = isForeground
    Task {
      await upsertActivity(
        for: latestStatus,
        canStartNewActivity: canStartNewActivity
      )
    }
  }

  private func endActivities() {
    guard #available(iOS 16.1, *) else {
      return
    }

    Task {
      for activity in Activity<ConnectionStatusAttributes>.activities {
        await activity.end(using: nil, dismissalPolicy: .immediate)
      }
    }
  }

  @available(iOS 16.1, *)
  private func upsertActivity(
    for status: StatusPayload,
    canStartNewActivity: Bool
  ) async {
    guard ActivityAuthorizationInfo().areActivitiesEnabled else {
      NSLog("Skipping SSH live activity because Live Activities are disabled.")
      return
    }

    let contentState = ConnectionStatusAttributes.ContentState(
      connectionCount: status.connectionCount,
      connectedCount: status.connectedCount
    )

    if let activity = Activity<ConnectionStatusAttributes>.activities.first {
      await activity.update(using: contentState)
      return
    }

    guard canStartNewActivity else {
      NSLog(
        "Skipping SSH live activity request because the app is not foregrounded."
      )
      return
    }

    do {
      _ = try Activity.request(
        attributes: ConnectionStatusAttributes(),
        contentState: contentState,
        pushType: nil
      )
    } catch {
      NSLog("Failed to start SSH live activity: %@", error.localizedDescription)
    }
  }
}
