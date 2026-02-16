import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  /// Background task identifier used to keep SSH connections alive
  /// for a short period after the app enters the background.
  private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid
  private var pendingTransferPayload: String?
  private let transferChannelName = "xyz.depollsoft.monkeyssh/transfer"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let controller = window?.rootViewController as? FlutterViewController {
      setupTransferChannel(with: controller)
    }
    if let launchUrl = launchOptions?[.url] as? URL {
      _ = handleTransferFile(url: launchUrl)
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    if handleTransferFile(url: url) {
      return true
    }
    return super.application(app, open: url, options: options)
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

  private func setupTransferChannel(with controller: FlutterViewController) {
    let channel = FlutterMethodChannel(
      name: transferChannelName,
      binaryMessenger: controller.binaryMessenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(nil)
        return
      }
      switch call.method {
      case "consumeIncomingTransferPayload":
        result(self.pendingTransferPayload)
        self.pendingTransferPayload = nil
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func handleTransferFile(url: URL) -> Bool {
    guard url.pathExtension.lowercased() == "monkeysshx" else {
      return false
    }
    do {
      pendingTransferPayload = try String(contentsOf: url, encoding: .utf8)
      return true
    } catch {
      pendingTransferPayload = nil
      return false
    }
  }
}
