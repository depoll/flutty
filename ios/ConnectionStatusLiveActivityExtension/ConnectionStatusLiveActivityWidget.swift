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
        monkeyLogoImage(
          named: "MonkeySSHDynamicIslandIcon",
          renderingMode: .alwaysOriginal
        )
          .resizable()
          .interpolation(.high)
          .scaledToFit()
          .frame(width: size, height: size)
      case .dynamicIsland:
        Image(dynamicIslandMonkeyLogoAssetName())
          .resizable()
          .interpolation(.high)
          .renderingMode(.original)
          .scaledToFit()
          .frame(width: size, height: size)
    }
  }

  private func dynamicIslandMonkeyLogoAssetName() -> String {
    let bundleIdentifier = Bundle.main.bundleIdentifier ?? ""
    if bundleIdentifier.contains(".private.") {
      return "DynamicIslandMonkeyMonochromePrivate"
    }
    return "DynamicIslandMonkeyMonochrome"
  }

  private func monkeyLogoImage(
    named imageName: String,
    renderingMode: UIImage.RenderingMode
  ) -> Image {
    guard
      let imagePath = Bundle.main.path(
        forResource: imageName,
        ofType: "png"
      ),
      let image = UIImage(contentsOfFile: imagePath)?
        .withRenderingMode(renderingMode)
    else {
      assertionFailure(
        "\(imageName).png is missing from the Live Activity extension bundle."
      )
      return Image(systemName: "network")
    }

    return Image(uiImage: image)
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
