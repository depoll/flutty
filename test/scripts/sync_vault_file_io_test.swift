import Foundation

@main
struct SyncVaultFileIOTests {
  static func testFileNames() {
    let names = [
      ("", "monkeyssh-sync-vault.monkeysync"),
      ("  work  ", "work.monkeysync"),
      ("日本語.MONKEYSYNC", "日本語.MONKEYSYNC"),
      ("../outside.monkeysync", "outside.monkeysync"),
      ("/absolute/path/vault", "vault.monkeysync"),
      ("../../", "monkeyssh-sync-vault.monkeysync")
    ]
    for (input, expected) in names {
      precondition(SyncVaultFileIO.normalizedFileName(input) == expected, input)
    }

  }

  static func main() throws {
    testFileNames()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let temporaryURL = try SyncVaultFileIO.writeTemporaryFile(
      contents: "encrypted fixture", suggestedFileName: "../outside.monkeysync",
      temporaryDirectory: root
    )
    precondition(temporaryURL.deletingLastPathComponent().path != root.path)
    precondition(temporaryURL.deletingLastPathComponent().deletingLastPathComponent().path == root.path)
    let exported = try String(contentsOf: temporaryURL, encoding: .utf8)
    precondition(exported == "encrypted fixture")

    let file = root.appendingPathComponent("read.monkeysync")
    for count in [0, 1, 65535, 65536, 65537, 131072] {
      let data = Data(repeating: 97, count: count)
      try data.write(to: file)
      let actual = try SyncVaultFileIO.readData(from: file, maxBytes: count)
      precondition(actual == data)
      if count > 0 {
        do {
          _ = try SyncVaultFileIO.readData(from: file, maxBytes: count - 1)
          preconditionFailure("Oversized vault accepted")
        } catch let error as NSError {
          precondition(error.domain == "SyncVaultDocument" && error.code == 5)
        }
      }
    }
    do {
      _ = try SyncVaultFileIO.readData(from: root.appendingPathComponent("missing"), maxBytes: 10)
      preconditionFailure("Missing vault accepted")
    } catch { }

    // A filename longer than NAME_MAX makes the atomic write fail after mkdir.
    let before = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
    do {
      _ = try SyncVaultFileIO.writeTemporaryFile(
        contents: "fixture", suggestedFileName: String(repeating: "x", count: 300),
        temporaryDirectory: root
      )
      preconditionFailure("Invalid filename accepted")
    } catch { }
    let after = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
    precondition(before == after, "Failed export leaked a temporary directory")
    print("Passed: 6 filename cases, confined export, 6 read boundaries, "
      + "5 size rejections, missing file, failed-write cleanup")
  }
}
