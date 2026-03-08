import ActivityKit

@available(iOS 16.1, *)
struct ConnectionStatusAttributes: ActivityAttributes {
  public struct ContentState: Codable, Hashable {
    let connectionCount: Int
    let connectedCount: Int
  }
}
