import SwiftUI

/// A compact, live-rotating view showing what tools Hermes is using in real time.
///
/// **Streaming**: cycles through tool labels one at a time with animated transitions.
/// **Finished**: shows a collapsed summary that expands to the full timeline on tap.
struct ToolActivityRail: View {
    let activities: [ToolActivity]
    let isStreaming: Bool

    @State private var isExpanded = false

    private var latestActivity: ToolActivity? {
        activities.last(where: { $0.isActive }) ?? activities.last
    }

    var body: some View {
        if !activities.isEmpty {
            if isStreaming {
                liveIndicator
            } else {
                finishedSummary
            }
        }
    }

    // MARK: - Live Streaming Indicator

    private var liveIndicator: some View {
        HStack(spacing: Design.Spacing.xs) {
            ProgressView()
                .controlSize(.mini)
                .tint(Design.Colors.secondaryForeground)

            if let latest = latestActivity {
                Text("\(latest.displayLabel) · \(latest.displayStatus(isStreaming: true))")
                    .font(Design.Typography.caption)
                    .foregroundStyle(Design.Colors.secondaryForeground)
                    .lineLimit(1)
                    .id(latest.id)
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .move(edge: .top).combined(with: .opacity)
                    ))
                    .animation(Design.Motion.quickResponse, value: latest.id)
            }
        }
        .padding(.horizontal, Design.Spacing.sm)
        .padding(.vertical, Design.Spacing.xxs + 1)
        .background(Design.Colors.surface)
        .clipShape(Capsule())
    }

    // MARK: - Finished Summary (expandable)

    private var finishedSummary: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.xxs) {
            Button {
                withAnimation(Design.Motion.quickResponse) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: Design.Spacing.xs) {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 10))
                        .foregroundStyle(Design.Colors.secondaryForeground)

                    Text("\(activities.count) tool activit\(activities.count == 1 ? "y" : "ies")")
                        .font(Design.Typography.caption)
                        .foregroundStyle(Design.Colors.secondaryForeground)

                    if !activities.isEmpty {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Design.Colors.secondaryForeground)
                    }
                }
                .padding(.horizontal, Design.Spacing.sm)
                .padding(.vertical, Design.Spacing.xxs + 1)
                .background(Design.Colors.surface)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Hide tool activity details" : "Show tool activity details")
            .accessibilityValue("\(activities.count) activities, \(isExpanded ? "expanded" : "collapsed")")

            if isExpanded {
                expandedTimeline
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(Design.Motion.quickResponse, value: isExpanded)
        .accessibilityElement(children: .contain)
    }

    // MARK: - Expanded Timeline

    private var expandedTimeline: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.xxxs) {
            ForEach(activities) { activity in
                HStack(spacing: Design.Spacing.xs) {
                    Circle()
                        .fill(Design.Colors.secondaryForeground)
                        .frame(width: 5, height: 5)

                    Text("\(activity.displayLabel) · \(activity.displayStatus(isStreaming: isStreaming))")
                        .font(Design.Typography.caption)
                        .foregroundStyle(Design.Colors.secondaryForeground)
                        .lineLimit(1)

                    Spacer()
                        .accessibilityHidden(true)

                    Text(activity.startedAt, style: .time)
                        .font(Design.Typography.caption2)
                        .foregroundStyle(Design.Colors.secondaryForeground)
                }
                .padding(.horizontal, Design.Spacing.xs)
                .padding(.vertical, Design.Spacing.xxxs)
            }
        }
        .padding(.vertical, Design.Spacing.xxs)
        .padding(.horizontal, Design.Spacing.xxs)
        .background(Design.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: Design.CornerRadius.sm))
    }
}
