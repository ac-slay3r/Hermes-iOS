import SwiftUI

struct SlashCommandMenu: View {
    let commands: [SlashCommand]
    let pinnedCommandIDs: [String]
    let onSelect: (SlashCommand) -> Void

    init(
        commands: [SlashCommand],
        pinnedCommandIDs: [String] = [],
        onSelect: @escaping (SlashCommand) -> Void
    ) {
        self.commands = commands
        self.pinnedCommandIDs = pinnedCommandIDs
        self.onSelect = onSelect
    }

    private var pinnedCommands: [SlashCommand] {
        let byID = Dictionary(uniqueKeysWithValues: commands.map { ($0.id, $0) })
        return pinnedCommandIDs.compactMap { byID[$0] }
    }

    private var groupedCommands: [(String, [SlashCommand])] {
        let pinned = Set(pinnedCommandIDs)
        let remaining = commands.filter { !pinned.contains($0.id) }
        return Dictionary(grouping: remaining, by: \.category)
            .map { category, values in
                (category, values.sorted { $0.displayTitle < $1.displayTitle })
            }
            .sorted { $0.0 < $1.0 }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                if !pinnedCommands.isEmpty {
                    Section {
                        commandRows(pinnedCommands)
                    } header: {
                        Text("Pinned")
                            .commandSectionHeader()
                    }
                }

                if !groupedCommands.isEmpty {
                    Text("All Commands")
                        .commandSectionHeader()
                    ForEach(groupedCommands, id: \.0) { category, categoryCommands in
                        Section {
                            commandRows(categoryCommands)
                        } header: {
                            Text(category)
                                .commandSectionHeader(secondary: true)
                        }
                    }
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: 360)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: Design.CornerRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: Design.CornerRadius.md)
                .stroke(Design.Colors.divider, lineWidth: 1)
        )
        .padding(.horizontal, Design.Spacing.md)
    }

    @ViewBuilder
    private func commandRows(_ values: [SlashCommand]) -> some View {
        ForEach(Array(values.enumerated()), id: \.element.id) { index, command in
            if index > 0 {
                Divider()
                    .background(Design.Colors.divider)
                    .padding(.horizontal, Design.Spacing.md)
            }

            Button { onSelect(command) } label: {
                HStack(spacing: Design.Spacing.sm) {
                    Text(command.displayTitle)
                        .font(.system(.subheadline, design: .monospaced, weight: .semibold))
                        .foregroundStyle(Design.Brand.accent)
                        .frame(width: 112, alignment: .leading)

                    Text(command.description)
                        .font(Design.Typography.caption)
                        .foregroundStyle(Design.Colors.secondaryForeground)
                        .lineLimit(2)

                    Spacer(minLength: 0)
                }
                .padding(.vertical, 10)
                .padding(.horizontal, Design.Spacing.md)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

private extension View {
    func commandSectionHeader(secondary: Bool = false) -> some View {
        self
            .font(secondary ? Design.Typography.caption : Design.Typography.callout)
            .fontWeight(.semibold)
            .foregroundStyle(secondary ? Design.Colors.secondaryForeground : Design.Colors.foreground)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Design.Spacing.md)
            .padding(.vertical, secondary ? Design.Spacing.xs : Design.Spacing.sm)
            .background(.ultraThinMaterial)
    }
}
