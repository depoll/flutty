import Flutter
import UIKit
#if canImport(ActivityKit)
import ActivityKit
#endif

#if canImport(ActivityKit)
@available(iOS 16.1, *)
private struct SshConnectionsAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable {
    let activeConnectionCount: Int
    let hostSummary: String
  }

  let name: String
}
#endif

@main
@objc class AppDelegate: FlutterAppDelegate {
  /// Background task identifier used to keep SSH connections alive
  /// for a short period after the app enters the background.
  private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid
  private let channelName = "xyz.depollsoft.monkeyssh/ssh_service"
#if canImport(ActivityKit)
  @available(iOS 16.1, *)
  private var sshConnectionsActivity: Activity<SshConnectionsAttributes>?
#endif

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    let didFinish = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(
        name: channelName,
        binaryMessenger: controller.binaryMessenger
      )
      channel.setMethodCallHandler { [weak self] call, result in
        guard let self else {
          result(
            FlutterError(
              code: "handler_unavailable",
              message: "MonkeySSH background activity handler is unavailable",
              details: nil
            )
          )
          return
        }

        switch call.method {
        case "syncLiveActivity":
          guard
            let arguments = call.arguments as? [String: Any],
            let activeConnectionCount = arguments["activeConnectionCount"] as? Int
          else {
            result(
              FlutterError(
                code: "invalid_arguments",
                message: "Missing activeConnectionCount",
                details: nil
              )
            )
            return
          }

          let hostSummary =
            arguments["hostSummary"] as? String ?? "SSH keep-alive is active"
          self.syncLiveActivity(
            activeConnectionCount: activeConnectionCount,
            hostSummary: hostSummary
          )
          result(nil)
        case "stopService":
          self.stopBackgroundIndicators(application)
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }
    return didFinish
  }

  override func applicationDidEnterBackground(_ application: UIApplication) {
    // Request extra background execution time so the Dart isolate can
    // continue processing SSH keepalive packets and responses.
    // iOS grants roughly 30 seconds before suspending the app.
    backgroundTaskId = application.beginBackgroundTask(withName: "SSHKeepAlive") {
      // Expiration handler — clean up when time runs out.
      application.endBackgroundTask(self.backgroundTaskId)
      self.backgroundTaskId = .invalid
    }
  }

  override func applicationWillEnterForeground(_ application: UIApplication) {
    // End the background task when returning to the foreground.
    if backgroundTaskId != .invalid {
      application.endBackgroundTask(backgroundTaskId)
      backgroundTaskId = .invalid
    }
  }

  private func syncLiveActivity(
    activeConnectionCount: Int,
    hostSummary: String
  ) {
    if activeConnectionCount <= 0 {
      stopBackgroundIndicators(UIApplication.shared)
      return
    }

    UIApplication.shared.applicationIconBadgeNumber = activeConnectionCount

#if canImport(ActivityKit)
    if #available(iOS 16.1, *) {
      guard ActivityAuthorizationInfo().areActivitiesEnabled else {
        return
      }

      let contentState = SshConnectionsAttributes.ContentState(
        activeConnectionCount: activeConnectionCount,
        hostSummary: hostSummary
      )

      Task {
        if let activity = sshConnectionsActivity {
          await activity.update(using: contentState)
        } else {
          do {
            sshConnectionsActivity = try Activity.request(
              attributes: SshConnectionsAttributes(name: "MonkeySSH"),
              contentState: contentState,
              pushType: nil
            )
          } catch {
            // Ignore Live Activity failures on unsupported devices/configurations.
          }
        }
      }
    }
#endif
  }

  private func stopBackgroundIndicators(_ application: UIApplication) {
    application.applicationIconBadgeNumber = 0

#if canImport(ActivityKit)
    if #available(iOS 16.1, *) {
      let activity = sshConnectionsActivity
      sshConnectionsActivity = nil
      Task {
        await activity?.end(dismissalPolicy: .immediate)
      }
    }
#endif

    if backgroundTaskId != .invalid {
      application.endBackgroundTask(backgroundTaskId)
      backgroundTaskId = .invalid
    }
  }
}
