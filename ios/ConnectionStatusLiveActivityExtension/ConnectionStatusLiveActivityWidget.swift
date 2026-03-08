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
          Text(context.state.primaryLabel)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }

        Text(context.state.primaryPreview ?? "Connected — waiting for terminal output")
          .font(.system(.caption, design: .monospaced))
          .lineLimit(3)
          .multilineTextAlignment(.leading)
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
          Text(context.state.primaryLabel)
            .font(.caption)
            .multilineTextAlignment(.trailing)
            .lineLimit(2)
        }
        DynamicIslandExpandedRegion(.bottom) {
          Text(context.state.primaryPreview ?? "Connected — waiting for terminal output")
            .font(.system(.caption, design: .monospaced))
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
}
