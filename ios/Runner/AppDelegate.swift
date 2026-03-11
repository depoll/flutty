import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private let channelName = "xyz.depollsoft.monkeyssh/ssh_service"
  private var backgroundSshChannel: FlutterMethodChannel?

  /// Background task identifier used to request a brief grace period
  /// before iOS suspends the app after entering the background.
  private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    guard let registrar = self.registrar(forPlugin: "BackgroundSshServiceBridge") else {
      NSLog("Failed to configure SSH background method channel registrar.")
      return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }
    backgroundSshChannel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )
    backgroundSshChannel?.setMethodCallHandler(handleBackgroundSshMethodCall)
    NSLog("Configured SSH background method channel.")
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private func handleBackgroundSshMethodCall(
    _ call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
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

      NSLog(
        "Received SSH background status update: %d total, %d connected.",
        connectionCount,
        connectedCount
      )
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

      NSLog("Received SSH app foreground state update: %@.", isForeground.description)
      if #available(iOS 16.1, *) {
        ConnectionStatusLiveActivityManager.shared.setForegroundState(
          isForeground: isForeground
        )
      }
      result(nil)
    case "stopService":
      NSLog("Received SSH background stop request.")
      if #available(iOS 16.1, *) {
        ConnectionStatusLiveActivityManager.shared.stop()
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  override func applicationDidEnterBackground(_ application: UIApplication) {
    if #available(iOS 16.1, *) {
      ConnectionStatusLiveActivityManager.shared.setForegroundState(
        isForeground: false
      )
    }

    // Request a brief amount of extra execution time so the Dart isolate can
    // flush any in-flight SSH keepalive traffic before iOS suspends the app.
    // The Live Activity remains a status surface only; it does not extend
    // background execution beyond this short grace period.
    backgroundTaskId = application.beginBackgroundTask(withName: "SSHKeepAlive") {
      // Expiration handler — clean up when time runs out.
      application.endBackgroundTask(self.backgroundTaskId)
      self.backgroundTaskId = .invalid
    }
  }

  override func applicationWillEnterForeground(_ application: UIApplication) {
    if #available(iOS 16.1, *) {
      ConnectionStatusLiveActivityManager.shared.setForegroundState(
        isForeground: true
      )
    }

    // End the background task when returning to the foreground.
    if backgroundTaskId != .invalid {
      application.endBackgroundTask(backgroundTaskId)
      backgroundTaskId = .invalid
    }
  }
}
