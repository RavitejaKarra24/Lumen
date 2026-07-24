import SwiftUI

struct AppsView: View {
    @Environment(AppState.self) private var appState
    @State private var query = ""

    var body: some View {
        @Bindable var appState = appState

        VStack(spacing: 0) {
            HStack {
                Text("Apps")
                    .font(.largeTitle.weight(.semibold))
                Spacer()
                DayPickerBar(day: $appState.selectedDay) { appState.selectDay($0) }
            }
            .padding(20)

            Divider()

            if let analytics = appState.analytics {
                let filtered = analytics.appUsages.filter {
                    query.isEmpty || $0.appName.localizedCaseInsensitiveContains(query)
                        || $0.bundleIdentifier.localizedCaseInsensitiveContains(query)
                }

                if filtered.isEmpty {
                    EmptyStateView(
                        symbol: "square.grid.2x2",
                        title: "No apps",
                        message: query.isEmpty
                            ? "App usage for this day will show up here."
                            : "No apps match “\(query)”."
                    )
                } else {
                    List {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { index, app in
                            HStack(spacing: 14) {
                                Text("\(index + 1)")
                                    .font(.headline.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 28, alignment: .trailing)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(app.appName)
                                        .font(.body.weight(.semibold))
                                    Text(app.bundleIdentifier)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }

                                Spacer()

                                CategoryBadge(category: app.category)

                                Text(DurationFormat.compact(app.duration))
                                    .font(.body.monospacedDigit().weight(.medium))
                                    .frame(width: 90, alignment: .trailing)

                                Text(shareLabel(app.duration, total: analytics.activeDuration))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 48, alignment: .trailing)
                            }
                            .padding(.vertical, 6)
                        }
                    }
                    .listStyle(.inset)
                    .searchable(text: $query, prompt: "Filter apps")
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func shareLabel(_ part: TimeInterval, total: TimeInterval) -> String {
        guard total > 0 else { return "—" }
        return String(format: "%.0f%%", (part / total) * 100)
    }
}
