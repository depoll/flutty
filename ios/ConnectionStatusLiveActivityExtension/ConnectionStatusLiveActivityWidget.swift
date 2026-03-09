import ActivityKit
import SwiftUI
import WidgetKit

@available(iOS 16.1, *)
struct ConnectionStatusLiveActivityWidget: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: ConnectionStatusAttributes.self) { context in
      VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .firstTextBaseline) {
          Label(
            "\(context.state.connectionCount) active",
            systemImage: "terminal.fill"
          )
          .font(.headline)
          Spacer()
          Text(connectionStatusSummary(for: context.state))
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.trailing)
        }

        Text("Keeping SSH connections alive in the background")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding()
      .activityBackgroundTint(Color.black)
      .activitySystemActionForegroundColor(Color.green)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          VStack(alignment: .leading, spacing: 4) {
            Text("SSH")
              .font(.caption2)
              .foregroundStyle(.secondary)
            Text("\(context.state.connectionCount) active")
              .font(.headline)
          }
        }
        DynamicIslandExpandedRegion(.trailing) {
          Text(connectionStatusSummary(for: context.state))
            .font(.caption)
            .multilineTextAlignment(.trailing)
            .lineLimit(2)
        }
        DynamicIslandExpandedRegion(.bottom) {
          Text("Keeping SSH connections alive in the background")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      } compactLeading: {
        Image(systemName: "terminal.fill")
      } compactTrailing: {
        Text("\(context.state.connectionCount)")
          .font(.caption2.bold())
      } minimal: {
        Text("\(context.state.connectionCount)")
          .font(.caption2.bold())
      }
    }
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
