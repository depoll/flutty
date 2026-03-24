import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private var pendingTransferPayload: String?
  private let transferChannelName = "xyz.depollsoft.monkeyssh/transfer"
  private let appleDatabaseChannelName = "xyz.depollsoft.monkeyssh/apple_file_protection"
  private let maxTransferPayloadBytes = 10 * 1024 * 1024
  private var transferChannel: FlutterMethodChannel?
  private var appleDatabaseChannel: FlutterMethodChannel?

  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)
    if let controller = mainFlutterWindow?.contentViewController as? FlutterViewController {
      setupTransferChannel(with: controller)
      setupAppleDatabaseChannel(with: controller)
    }
  }

  override func application(_ sender: NSApplication, openFile filename: String) -> Bool {
    guard filename.lowercased().hasSuffix(".monkeysshx") else {
      return false
    }
    do {
      pendingTransferPayload = try readTransferPayload(from: URL(fileURLWithPath: filename))
      notifyIncomingTransferPayload()
      return true
    } catch {
      pendingTransferPayload = nil
      return false
    }
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  private func setupTransferChannel(with controller: FlutterViewController) {
    let channel = FlutterMethodChannel(
      name: transferChannelName,
      binaryMessenger: controller.engine.binaryMessenger
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

  private func setupAppleDatabaseChannel(with controller: FlutterViewController) {
    let channel = FlutterMethodChannel(
      name: appleDatabaseChannelName,
      binaryMessenger: controller.engine.binaryMessenger
    )
    appleDatabaseChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(nil)
        return
      }
      switch call.method {
      case "applyDatabaseFilePolicy":
        self.handleAppleDatabaseMethodCall(call, result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
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

    do {
      try applyAppleDatabaseFilePolicy(
        databaseDirectoryPath: databaseDirectoryPath,
        databasePath: databasePath,
        companionPaths: companionPaths
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

  private func applyAppleDatabaseFilePolicy(
    databaseDirectoryPath: String,
    databasePath: String,
    companionPaths: [String]
  ) throws {
    try excludeFromBackup(path: databaseDirectoryPath)

    for path in [databasePath] + companionPaths {
      guard FileManager.default.fileExists(atPath: path) else {
        continue
      }
      try excludeFromBackup(path: path)
    }
  }

  private func excludeFromBackup(path: String) throws {
    var url = URL(fileURLWithPath: path)
    var resourceValues = URLResourceValues()
    resourceValues.isExcludedFromBackup = true
    try url.setResourceValues(resourceValues)
  }
}
