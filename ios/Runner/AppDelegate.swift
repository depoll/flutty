import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private let channelName = "xyz.depollsoft.monkeyssh/ssh_service"
  private let transferChannelName = "xyz.depollsoft.monkeyssh/transfer"
  private let appleDatabaseChannelName = "xyz.depollsoft.monkeyssh/apple_file_protection"
  private let maxTransferPayloadBytes = 10 * 1024 * 1024
  private var backgroundSshChannel: FlutterMethodChannel?
  private var transferChannel: FlutterMethodChannel?
  private var appleDatabaseChannel: FlutterMethodChannel?
  private var pendingTransferPayload: String?

  /// Background task identifier used to request a brief grace period
  /// before iOS suspends the app after entering the background.
  private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let registrar = self.registrar(forPlugin: "AppDelegateBridge") {
      setupBackgroundSshChannel(with: registrar)
      setupTransferChannel(with: registrar)
      setupAppleDatabaseChannel(with: registrar)
    } else {
      NSLog("Failed to configure AppDelegate method channels.")
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

  private func setupBackgroundSshChannel(with registrar: FlutterPluginRegistrar) {
    backgroundSshChannel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )
    backgroundSshChannel?.setMethodCallHandler(handleBackgroundSshMethodCall)
    NSLog("Configured SSH background method channel.")
  }

  private func setupTransferChannel(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: transferChannelName,
      binaryMessenger: registrar.messenger()
    )
    transferChannel = channel
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
    notifyIncomingTransferPayload()
  }

  private func setupAppleDatabaseChannel(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: appleDatabaseChannelName,
      binaryMessenger: registrar.messenger()
    )
    appleDatabaseChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard self != nil else {
        result(nil)
        return
      }
      switch call.method {
      case "applyDatabaseFilePolicy":
        self?.handleAppleDatabaseMethodCall(call, result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
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

  private func handleAppleDatabaseMethodCall(
    _ call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    guard
      let arguments = call.arguments as? [String: Any],
      let databaseDirectoryPath = arguments["databaseDirectoryPath"] as? String,
      let databasePath = arguments["databasePath"] as? String,
      let companionPaths = arguments["companionPaths"] as? [String]
    else {
      result(
        FlutterError(
          code: "invalid_args",
          message: "Missing Apple database file policy arguments",
          details: nil
        )
      )
      return
    }

    let applyFileProtection =
      arguments["applyFileProtection"] as? Bool ?? true

    do {
      try applyAppleDatabaseFilePolicy(
        databaseDirectoryPath: databaseDirectoryPath,
        databasePath: databasePath,
        companionPaths: companionPaths,
        applyFileProtection: applyFileProtection
      )
      result(nil)
    } catch {
      result(
        FlutterError(
          code: "file_policy_error",
          message: "Failed to apply Apple database file policy",
          details: error.localizedDescription
        )
      )
    }
  }

  private func handleTransferFile(url: URL) -> Bool {
    guard url.pathExtension.lowercased() == "monkeysshx" else {
      return false
    }
    let accessedSecurityScopedResource = url.startAccessingSecurityScopedResource()
    defer {
      if accessedSecurityScopedResource {
        url.stopAccessingSecurityScopedResource()
      }
    }
    do {
      pendingTransferPayload = try readTransferPayload(from: url)
      notifyIncomingTransferPayload()
      return true
    } catch {
      pendingTransferPayload = nil
      return false
    }
  }

  private func readTransferPayload(from url: URL) throws -> String {
    let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
    if let fileSize, fileSize > maxTransferPayloadBytes {
      throw NSError(domain: "MonkeySSHTransfer", code: 1)
    }
    let data = try Data(contentsOf: url, options: [.mappedIfSafe])
    if data.count > maxTransferPayloadBytes {
      throw NSError(domain: "MonkeySSHTransfer", code: 1)
    }
    guard let payload = String(data: data, encoding: .utf8) else {
      throw NSError(domain: "MonkeySSHTransfer", code: 2)
    }
    return payload
  }

  private func notifyIncomingTransferPayload() {
    guard let payload = pendingTransferPayload else {
      return
    }
    transferChannel?.invokeMethod("onIncomingTransferPayload", arguments: payload)
  }

  private func applyAppleDatabaseFilePolicy(
    databaseDirectoryPath: String,
    databasePath: String,
    companionPaths: [String],
    applyFileProtection: Bool
  ) throws {
    try excludeFromBackup(path: databaseDirectoryPath)
    if applyFileProtection {
      try applyFileProtectionClass(path: databaseDirectoryPath)
    }

    for path in [databasePath] + companionPaths {
      guard FileManager.default.fileExists(atPath: path) else {
        continue
      }
      try excludeFromBackup(path: path)
      if applyFileProtection {
        try applyFileProtectionClass(path: path)
      }
    }
  }

  private func excludeFromBackup(path: String) throws {
    var url = URL(fileURLWithPath: path)
    var resourceValues = URLResourceValues()
    resourceValues.isExcludedFromBackup = true
    try url.setResourceValues(resourceValues)
  }

  private func applyFileProtectionClass(path: String) throws {
    try FileManager.default.setAttributes(
      [
        .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
      ],
      ofItemAtPath: path
    )
  }
}
