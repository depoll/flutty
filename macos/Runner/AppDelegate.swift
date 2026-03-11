import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private var pendingTransferPayload: String?
  private let transferChannelName = "xyz.depollsoft.monkeyssh/transfer"
  private let maxTransferPayloadBytes = 10 * 1024 * 1024
  private var transferChannel: FlutterMethodChannel?

  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)
    if let controller = NSApplication.shared.windows.first?.contentViewController as? FlutterViewController {
      setupTransferChannel(with: controller)
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
}
