import SwiftUI

struct WebsitesView: View {
    @Environment(AppState.self) private var appState
    @State private var query = ""

    var body: some View {
        @Bindable var appState = appState

        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Websites")
                        .font(.largeTitle.weight(.semibold))
                    if !appState.permissions.hasAccessibility {
                        Label("Accessibility required to capture URLs", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer()
                DayPickerBar(day: $appState.selectedDay) { appState.selectDay($0) }
            }
            .padding(20)

            Divider()

            if let analytics = appState.analytics {
                let filtered = analytics.domainUsages.filter {
                    query.isEmpty || $0.domain.localizedCaseInsensitiveContains(query)
                }
                let total = filtered.reduce(0.0) { $0 + $1.duration }

                if filtered.isEmpty {
                    EmptyStateView(
                        symbol: "globe",
                        title: query.isEmpty ? "No websites yet" : "No matching websites",
                        message: emptyStateMessage,
                        actionTitle: !appState.permissions.hasAccessibility && query.isEmpty
                            ? "Grant Accessibility"
                            : nil,
                        action: {
                            appState.permissions.requestAccessibility()
                        }
                    )
                } else {
                    List {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { index, site in
                            HStack(spacing: 14) {
                                Text("\(index + 1)")
                                    .font(.headline.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 28, alignment: .trailing)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(site.domain)
                                        .font(.body.weight(.semibold))
                                        .textSelection(.enabled)
                                    Text("\(site.visitCount) visit\(site.visitCount == 1 ? "" : "s")")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                // Mini bar
                                GeometryReader { geo in
                                    let ratio = total > 0 ? site.duration / total : 0
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(Color.primary.opacity(0.06))
                                        Capsule()
                                            .fill(Color.cyan.gradient)
                                            .frame(width: max(4, geo.size.width * ratio))
                                    }
                                }
                                .frame(width: 120, height: 6)

                                Text(DurationFormat.compact(site.duration))
                                    .font(.body.monospacedDigit().weight(.medium))
                                    .frame(width: 90, alignment: .trailing)
                            }
                            .padding(.vertical, 6)
                        }
                    }
                    .listStyle(.inset)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Attached to the container, not the list: when a query matched nothing the
        // search field disappeared along with the list, stranding the user.
        .searchable(text: $query, prompt: "Filter domains")
    }

    private var emptyStateMessage: String {
        if !query.isEmpty {
            return "No websites match “\(query)”."
        }
        if appState.permissions.hasAccessibility {
            return "Browse the web and Lumen will log domains and time spent."
        }
        return "Lumen needs Accessibility access to read the active browser address."
    }
}
