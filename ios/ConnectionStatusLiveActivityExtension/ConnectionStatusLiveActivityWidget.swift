import ActivityKit
import SwiftUI
import UIKit
import WidgetKit

@available(iOS 16.1, *)
struct ConnectionStatusLiveActivityWidget: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: ConnectionStatusAttributes.self) { context in
      VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .firstTextBaseline) {
          HStack(spacing: 8) {
            monkeyLogo(size: 20)
            Text("\(context.state.connectionCount) active")
              .font(.headline)
          }
          Spacer()
          Text(connectionStatusSummary(for: context.state))
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.trailing)
        }

        Text("Showing the last known SSH status")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding()
      .activityBackgroundTint(Color.black)
      .activitySystemActionForegroundColor(Color.green)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          HStack(spacing: 8) {
            monkeyLogo(size: 24, style: .dynamicIsland)
            VStack(alignment: .leading, spacing: 4) {
              Text("SSH")
                .font(.caption2)
                .foregroundStyle(.secondary)
              Text("\(context.state.connectionCount) active")
                .font(.headline)
            }
          }
        }
        DynamicIslandExpandedRegion(.trailing) {
          Text(connectionStatusSummary(for: context.state))
            .font(.caption)
            .multilineTextAlignment(.trailing)
            .lineLimit(2)
        }
        DynamicIslandExpandedRegion(.bottom) {
          Text("Showing the last known SSH status")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      } compactLeading: {
        monkeyLogo(size: 32, style: .dynamicIsland)
      } compactTrailing: {
        Text("\(context.state.connectionCount)")
          .font(.caption2.bold())
      } minimal: {
        monkeyLogo(
          size: 32,
          style: .dynamicIsland,
          accessibilityLabel: "MonkeySSH"
        )
      }
    }
  }

  private enum MonkeyLogoStyle {
    case fullColor
    case dynamicIsland
  }

  private enum MonkeyLogoAssetAvailability {
    static let lock = NSLock()
    static var availabilityByName: [String: Bool] = [:]
    static var loggedMissingAssetNames: Set<String> = []

    static func assetNameIfAvailable(_ assetName: String) -> String? {
      lock.lock()
      if let isAvailable = availabilityByName[assetName] {
        lock.unlock()
        return isAvailable ? assetName : nil
      }
      lock.unlock()

      let isAvailable = UIImage(
        named: assetName,
        in: .main,
        compatibleWith: nil
      ) != nil

      var shouldLogMissing = false
      lock.lock()
      availabilityByName[assetName] = isAvailable
      if !isAvailable {
        shouldLogMissing = loggedMissingAssetNames.insert(assetName).inserted
      }
      lock.unlock()

      if shouldLogMissing {
        NSLog("Missing \(assetName) asset in live activity bundle.")
      }
      return isAvailable ? assetName : nil
    }
  }

  @ViewBuilder
  private func monkeyLogo(
    size: CGFloat,
    style: MonkeyLogoStyle = .fullColor,
    accessibilityLabel: String? = nil
  ) -> some View {
    if let accessibilityLabel {
      baseMonkeyLogo(size: size, style: style)
        .accessibilityLabel(Text(accessibilityLabel))
    } else {
      baseMonkeyLogo(size: size, style: style)
        .accessibilityHidden(true)
    }
  }

  @ViewBuilder
  private func baseMonkeyLogo(
    size: CGFloat,
    style: MonkeyLogoStyle
  ) -> some View {
    switch style {
      case .fullColor:
        if let assetName = fullColorMonkeyLogoAssetName() {
          Image(assetName)
            .resizable()
            .interpolation(.high)
            .renderingMode(.original)
            .scaledToFit()
            .frame(width: size, height: size)
        } else {
          fallbackMonkeyLogo(size: size, style: style)
        }
      case .dynamicIsland:
        if let assetName = dynamicIslandMonkeyLogoAssetName() {
          Image(assetName)
            .resizable()
            .interpolation(.high)
            .renderingMode(.original)
            .scaledToFit()
            .frame(width: size, height: size)
        } else {
          fallbackMonkeyLogo(size: size, style: style)
        }
    }
  }

  @ViewBuilder
  private func fallbackMonkeyLogo(
    size: CGFloat,
    style: MonkeyLogoStyle
  ) -> some View {
    switch style {
      case .fullColor:
        Image(systemName: "terminal.fill")
          .resizable()
          .scaledToFit()
          .frame(width: size, height: size)
          .foregroundStyle(.white)
      case .dynamicIsland:
        Image(systemName: "network")
          .resizable()
          .scaledToFit()
          .frame(width: size, height: size)
          .foregroundStyle(.white)
    }
  }

  private func fullColorMonkeyLogoAssetName() -> String? {
    MonkeyLogoAssetAvailability.assetNameIfAvailable("MonkeySSHDynamicIslandIcon")
  }

  private func dynamicIslandMonkeyLogoAssetName() -> String? {
    let bundleIdentifier = Bundle.main.bundleIdentifier ?? ""
    let assetName =
      bundleIdentifier.contains(".private.")
      ? "DynamicIslandMonkeyMonochromePrivate"
      : "DynamicIslandMonkeyMonochrome"
    return MonkeyLogoAssetAvailability.assetNameIfAvailable(assetName)
  }

  private func connectionStatusSummary(
    for state: ConnectionStatusAttributes.ContentState
  ) -> String {
    if state.connectedCount == state.connectionCount {
      return "All sessions connected"
    }
    return "\(state.connectedCount)/\(state.connectionCount) connected"
  }
}
