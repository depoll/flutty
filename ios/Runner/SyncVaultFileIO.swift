import Foundation

/// File operations shared by the vault picker and its bookmarked-file bridge.
enum SyncVaultFileIO {
  static func normalizedFileName(_ fileName: String) -> String {
    let trimmed = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
    let leaf = (trimmed as NSString).lastPathComponent
    let baseName = leaf.isEmpty || leaf == "." || leaf == ".." || leaf == "/"
      ? "monkeyssh-sync-vault" : leaf
    return baseName.lowercased().hasSuffix(".monkeysync") ? baseName : "\(baseName).monkeysync"
  }

  static func writeTemporaryFile(
    contents: String,
    suggestedFileName: String,
    temporaryDirectory: URL = FileManager.default.temporaryDirectory
  ) throws -> URL {
    let directory = temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    do {
      let url = directory.appendingPathComponent(normalizedFileName(suggestedFileName))
      try Data(contents.utf8).write(to: url, options: .atomic)
      return url
    } catch {
      try? FileManager.default.removeItem(at: directory)
      throw error
    }
  }

  static func readData(from url: URL, maxBytes: Int) throws -> Data {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var data = Data()
    // Read one byte beyond the limit to distinguish an exact fit from overflow.
    // Do not trust provider file-size metadata or map an unbounded cloud file.
    while let chunk = try handle.read(upToCount: min(64 * 1024, maxBytes - data.count + 1)),
      !chunk.isEmpty {
      guard chunk.count <= maxBytes - data.count else {
        throw NSError(
          domain: "SyncVaultDocument", code: 5,
          userInfo: [NSLocalizedDescriptionKey: "Sync vault file is too large"]
        )
      }
      data.append(chunk)
    }
    return data
  }
}
