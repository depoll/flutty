import Flutter
import UIKit
import UniformTypeIdentifiers

@main
@objc class AppDelegate: FlutterAppDelegate, UIDocumentPickerDelegate {
  private let channelName = "xyz.depollsoft.monkeyssh/ssh_service"
  private let transferChannelName = "xyz.depollsoft.monkeyssh/transfer"
  private let appleDatabaseChannelName = "xyz.depollsoft.monkeyssh/apple_file_protection"
  private let syncVaultDocumentChannelName = "xyz.depollsoft.monkeyssh/sync_vault_document"
  private let maxTransferPayloadBytes = 10 * 1024 * 1024
  private let maxSyncVaultBytes = 10 * 1024 * 1024
  private var backgroundSshChannel: FlutterMethodChannel?
  private var transferChannel: FlutterMethodChannel?
  private var appleDatabaseChannel: FlutterMethodChannel?
  private var syncVaultDocumentChannel: FlutterMethodChannel?
  private var pendingTransferPayload: String?
  private var pendingSyncVaultOperation: PendingSyncVaultOperation?

  /// Background task identifier used to request a brief grace period
  /// before iOS suspends the app after entering the background.
  private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid

  private struct PendingSyncVaultOperation {
    let kind: SyncVaultOperationKind
    let result: FlutterResult
    let temporaryURL: URL?
  }

  private enum SyncVaultOperationKind {
    case create
    case pick
  }

  private enum SyncVaultDocumentError: Int {
    case invalidArguments = 1
    case pickerBusy = 2
    case presentationFailed = 3
    case invalidExtension = 4
    case fileTooLarge = 5
    case invalidFormat = 6
    case accessFailed = 7
  }

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let registrar = self.registrar(forPlugin: "AppDelegateBridge") {
      setupBackgroundSshChannel(with: registrar)
      setupTransferChannel(with: registrar)
      setupAppleDatabaseChannel(with: registrar)
      setupSyncVaultDocumentChannel(with: registrar)
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

  private func setupSyncVaultDocumentChannel(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: syncVaultDocumentChannelName,
      binaryMessenger: registrar.messenger()
    )
    syncVaultDocumentChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(nil)
        return
      }
      self.handleSyncVaultDocumentMethodCall(call, result: result)
    }
  }

  private func handleSyncVaultDocumentMethodCall(
    _ call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    switch call.method {
    case "createLinkedVault":
      handleCreateLinkedVault(call, result: result)
    case "pickLinkedVault":
      handlePickLinkedVault(result: result)
    default:
      result(FlutterMethodNotImplemented)
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

  private func handleCreateLinkedVault(
    _ call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    guard pendingSyncVaultOperation == nil else {
      result(
        flutterSyncVaultError(
          code: .pickerBusy,
          message: "A sync vault picker is already in progress"
        )
      )
      return
    }
    guard
      let arguments = call.arguments as? [String: Any],
      let encryptedVault = arguments["encryptedVault"] as? String,
      let suggestedFileName = arguments["suggestedFileName"] as? String
    else {
      result(
        flutterSyncVaultError(
          code: .invalidArguments,
          message: "Missing sync vault creation arguments"
        )
      )
      return
    }

    do {
      let temporaryURL = try writeTemporarySyncVaultFile(
        contents: encryptedVault,
        suggestedFileName: suggestedFileName
      )
      let picker: UIDocumentPickerViewController
      if #available(iOS 14.0, *) {
        picker = UIDocumentPickerViewController(
          forExporting: [temporaryURL],
          asCopy: false
        )
      } else {
        picker = UIDocumentPickerViewController(url: temporaryURL, in: .exportToService)
      }
      picker.delegate = self
      picker.allowsMultipleSelection = false
      pendingSyncVaultOperation = PendingSyncVaultOperation(
        kind: .create,
        result: result,
        temporaryURL: temporaryURL
      )
      try presentSyncVaultPicker(picker)
    } catch {
      cleanupPendingSyncVaultOperation()
      result(flutterSyncVaultError(from: error))
    }
  }

  private func handlePickLinkedVault(result: @escaping FlutterResult) {
    guard pendingSyncVaultOperation == nil else {
      result(
        flutterSyncVaultError(
          code: .pickerBusy,
          message: "A sync vault picker is already in progress"
        )
      )
      return
    }

    do {
      let picker: UIDocumentPickerViewController
      if #available(iOS 14.0, *) {
        picker = UIDocumentPickerViewController(
          forOpeningContentTypes: [.data],
          asCopy: false
        )
      } else {
        picker = UIDocumentPickerViewController(documentTypes: ["public.data"], in: .open)
      }
      picker.delegate = self
      picker.allowsMultipleSelection = false
      pendingSyncVaultOperation = PendingSyncVaultOperation(
        kind: .pick,
        result: result,
        temporaryURL: nil
      )
      try presentSyncVaultPicker(picker)
    } catch {
      cleanupPendingSyncVaultOperation()
      result(flutterSyncVaultError(from: error))
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
    let validatedPaths = try validatedDatabaseFilePolicyPaths(
      databaseDirectoryPath: databaseDirectoryPath,
      databasePath: databasePath,
      companionPaths: companionPaths
    )

    try excludeFromBackup(path: validatedPaths.databaseDirectoryPath)
    if applyFileProtection {
      try applyFileProtectionClass(path: validatedPaths.databaseDirectoryPath)
    }

    for path in [validatedPaths.databasePath] + validatedPaths.companionPaths {
      guard FileManager.default.fileExists(atPath: path) else {
        continue
      }
      try excludeFromBackup(path: path)
      if applyFileProtection {
        try applyFileProtectionClass(path: path)
      }
    }
  }

  private func validatedDatabaseFilePolicyPaths(
    databaseDirectoryPath: String,
    databasePath: String,
    companionPaths: [String]
  ) throws -> (databaseDirectoryPath: String, databasePath: String, companionPaths: [String]) {
    func canonicalURL(for path: String) -> URL {
      URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
    }

    let baseURL = canonicalURL(for: databaseDirectoryPath)
    let basePath = baseURL.path.hasSuffix("/") ? baseURL.path : baseURL.path + "/"

    func validatedPath(_ path: String, kind: String) throws -> String {
      let canonicalPath = canonicalURL(for: path).path
      if canonicalPath == baseURL.path || canonicalPath.hasPrefix(basePath) {
        return canonicalPath
      }

      throw NSError(
        domain: "AppleDatabaseFilePolicy",
        code: 1,
        userInfo: [
          NSLocalizedDescriptionKey:
            "\(kind) path is outside the database directory: \(path)"
        ]
      )
    }

    return (
      databaseDirectoryPath: baseURL.path,
      databasePath: try validatedPath(databasePath, kind: "Database"),
      companionPaths: try companionPaths.map { path in
        try validatedPath(path, kind: "Companion")
      }
    )
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    guard let pendingOperation = pendingSyncVaultOperation else {
      return
    }
    pendingOperation.result(nil)
    cleanupPendingSyncVaultOperation()
  }

  func documentPicker(
    _ controller: UIDocumentPickerViewController,
    didPickDocumentsAt urls: [URL]
  ) {
    guard let pendingOperation = pendingSyncVaultOperation else {
      return
    }
    defer { cleanupPendingSyncVaultOperation() }

    guard let url = urls.first else {
      pendingOperation.result(nil)
      return
    }

    do {
      switch pendingOperation.kind {
      case .create:
        pendingOperation.result(try createdSyncVaultResult(for: url))
      case .pick:
        pendingOperation.result(try pickedSyncVaultResult(for: url))
      }
    } catch {
      pendingOperation.result(flutterSyncVaultError(from: error))
    }
  }

  private func presentSyncVaultPicker(_ picker: UIDocumentPickerViewController) throws {
    guard let presenter = topViewController() else {
      throw syncVaultError(
        code: .presentationFailed,
        message: "Could not present the sync vault picker"
      )
    }
    presenter.present(picker, animated: true)
  }

  private func topViewController(
    from rootViewController: UIViewController? = nil
  ) -> UIViewController? {
    let root = rootViewController ?? window?.rootViewController
    if let navigationController = root as? UINavigationController {
      return topViewController(from: navigationController.visibleViewController)
    }
    if let tabBarController = root as? UITabBarController {
      return topViewController(from: tabBarController.selectedViewController)
    }
    if let presentedViewController = root?.presentedViewController {
      return topViewController(from: presentedViewController)
    }
    return root
  }

  private func cleanupPendingSyncVaultOperation() {
    defer { pendingSyncVaultOperation = nil }
    guard let temporaryURL = pendingSyncVaultOperation?.temporaryURL else {
      return
    }
    try? FileManager.default.removeItem(at: temporaryURL.deletingLastPathComponent())
  }

  private func createdSyncVaultResult(for url: URL) throws -> [String: Any] {
    try validateSyncVaultExtension(for: url)
    return [
      "path": url.path
    ]
  }

  private func pickedSyncVaultResult(for url: URL) throws -> [String: Any] {
    try validateSyncVaultExtension(for: url)
    return try accessSyncVaultURL(url) { accessedURL in
      [
        "path": accessedURL.path,
        "contents": try readSyncVaultContents(from: accessedURL)
      ]
    }
  }

  private func accessSyncVaultURL<T>(
    _ url: URL,
    _ body: (URL) throws -> T
  ) throws -> T {
    let accessedResource = url.startAccessingSecurityScopedResource()
    defer {
      if accessedResource {
        url.stopAccessingSecurityScopedResource()
      }
    }
    return try body(url)
  }

  private func validateSyncVaultExtension(for url: URL) throws {
    guard url.pathExtension.lowercased() == "monkeysync" else {
      throw syncVaultError(
        code: .invalidExtension,
        message: "Select a .monkeysync sync vault file"
      )
    }
  }

  private func writeTemporarySyncVaultFile(
    contents: String,
    suggestedFileName: String
  ) throws -> URL {
    let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString,
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: tempDirectory,
      withIntermediateDirectories: true
    )
    let normalizedFileName = normalizedSyncVaultFileName(suggestedFileName)
    let temporaryURL = tempDirectory.appendingPathComponent(normalizedFileName)
    try Data(contents.utf8).write(to: temporaryURL, options: .atomic)
    return temporaryURL
  }

  private func normalizedSyncVaultFileName(_ fileName: String) -> String {
    let trimmed = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
    let baseName = trimmed.isEmpty ? "monkeyssh-sync-vault" : trimmed
    if baseName.lowercased().hasSuffix(".monkeysync") {
      return baseName
    }
    return "\(baseName).monkeysync"
  }

  private func readSyncVaultContents(from url: URL) throws -> String {
    let data = try coordinatedReadData(from: url)
    if data.count > maxSyncVaultBytes {
      throw syncVaultError(
        code: .fileTooLarge,
        message: "Sync vault file is too large"
      )
    }
    guard let contents = String(data: data, encoding: .utf8) else {
      throw syncVaultError(
        code: .invalidFormat,
        message: "Invalid sync vault file format"
      )
    }
    return contents
  }

  private func coordinatedReadData(from url: URL) throws -> Data {
    let coordinator = NSFileCoordinator(filePresenter: nil)
    var coordinationError: NSError?
    var readError: Error?
    var data = Data()
    coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) {
      coordinatedURL in
      do {
        data = try Data(contentsOf: coordinatedURL, options: [.mappedIfSafe])
      } catch {
        readError = error
      }
    }
    if let coordinationError {
      throw coordinationError
    }
    if let readError {
      throw readError
    }
    return data
  }

  private func syncVaultError(
    code: SyncVaultDocumentError,
    message: String
  ) -> NSError {
    NSError(
      domain: "SyncVaultDocument",
      code: code.rawValue,
      userInfo: [NSLocalizedDescriptionKey: message]
    )
  }

  private func flutterSyncVaultError(
    code: SyncVaultDocumentError,
    message: String
  ) -> FlutterError {
    FlutterError(
      code: flutterSyncVaultErrorCode(for: code),
      message: message,
      details: nil
    )
  }

  private func flutterSyncVaultError(from error: Error) -> FlutterError {
    let nsError = error as NSError
    let mappedCode =
      SyncVaultDocumentError(rawValue: nsError.code) ?? .accessFailed
    return FlutterError(
      code: flutterSyncVaultErrorCode(for: mappedCode),
      message:
        nsError.localizedDescription.isEmpty
        ? "Could not access the linked sync vault"
        : nsError.localizedDescription,
      details: nil
    )
  }

  private func flutterSyncVaultErrorCode(for code: SyncVaultDocumentError) -> String {
    switch code {
    case .invalidArguments:
      return "invalid_args"
    case .pickerBusy:
      return "picker_busy"
    case .presentationFailed:
      return "presentation_failed"
    case .invalidExtension:
      return "invalid_extension"
    case .fileTooLarge:
      return "file_too_large"
    case .invalidFormat:
      return "invalid_format"
    case .accessFailed:
      return "access_failed"
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
