import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private let channelName = "xyz.depollsoft.monkeyssh/ssh_service"

  /// Background task identifier used to keep SSH connections alive
  /// for a short period after the app enters the background.
  private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(
        name: channelName,
        binaryMessenger: controller.binaryMessenger
      )
      channel.setMethodCallHandler { call, result in
        switch call.method {
        case "updateStatus":
          guard
            let arguments = call.arguments as? [String: Any],
            let connectionCount = arguments["connectionCount"] as? Int,
            let connectedCount = arguments["connectedCount"] as? Int
          else {
            result(
              FlutterError(
                code: "invalid_args",
                message: "Missing live activity status arguments",
                details: nil
              )
            )
            return
          }

          if #available(iOS 16.1, *) {
            ConnectionStatusLiveActivityManager.shared.updateStatus(
              connectionCount: connectionCount,
              connectedCount: connectedCount
            )
          }
          result(nil)
        case "setForegroundState":
          guard
            let arguments = call.arguments as? [String: Any],
            let isForeground = arguments["isForeground"] as? Bool
          else {
            result(
              FlutterError(
                code: "invalid_args",
                message: "Missing foreground state argument",
                details: nil
              )
            )
            return
          }

          if #available(iOS 16.1, *) {
            ConnectionStatusLiveActivityManager.shared.setForegroundState(
              isForeground: isForeground
            )
          }
          result(nil)
        case "stopService":
          if #available(iOS 16.1, *) {
            ConnectionStatusLiveActivityManager.shared.stop()
          }
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
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
}
