import SwiftUI

struct TagsView: View {
    @Environment(AppState.self) private var appState
    @State private var newTag = ""
    @State private var selectedTag: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Tags")
                    .font(.largeTitle.weight(.semibold))
                Spacer()
            }
            .padding(20)

            Divider()

            HSplitView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        TextField("New tag", text: $newTag)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(create)
                        Button("Add", action: create)
                            .disabled(newTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)

                    if appState.tagDefinitions.isEmpty {
                        Text("Create tags to label sessions from the Timeline.")
                            .foregroundStyle(.secondary)
                            .padding(16)
                        Spacer()
                    } else {
                        List(selection: $selectedTag) {
                            ForEach(appState.tagDefinitions) { tag in
                                HStack {
                                    Circle()
                                        .fill(Color(hex: tag.colorHex) ?? .orange)
                                        .frame(width: 10, height: 10)
                                    Text(tag.name)
                                    Spacer()
                                    Text("\(usageCount(for: tag.name))")
                                        .foregroundStyle(.secondary)
                                        .font(.caption.monospacedDigit())
                                }
                                .tag(tag.name as String?)
                                .contextMenu {
                                    Button("Delete", role: .destructive) {
                                        appState.deleteTagDefinition(tag)
                                        if selectedTag == tag.name { selectedTag = nil }
                                    }
                                }
                            }
                        }
                        .listStyle(.inset)
                    }
                }
                .frame(minWidth: 260, idealWidth: 280)

                sessionsForSelectedTag
                    .frame(minWidth: 400)
            }
        }
    }

    @ViewBuilder
    private var sessionsForSelectedTag: some View {
        if let selectedTag {
            let matches = (appState.analytics?.segments ?? []).filter {
                $0.tags.contains(where: { $0.caseInsensitiveCompare(selectedTag) == .orderedSame })
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("Sessions tagged “\(selectedTag)” on \(appState.selectedDay.formatted(date: .abbreviated, time: .omitted))")
                    .font(.headline)
                    .padding(16)
                Divider()
                if matches.isEmpty {
                    EmptyStateView(
                        symbol: "tag",
                        title: "No sessions",
                        message: "Tag timeline sessions with “\(selectedTag)” to see them here."
                    )
                } else {
                    List(matches) { segment in
                        TimelineRow(segment: segment)
                    }
                    .listStyle(.inset)
                }
            }
        } else {
            EmptyStateView(
                symbol: "tag.fill",
                title: "Tags",
                message: "Organize deep work, meetings, clients, or learning with manual tags."
            )
        }
    }

    private func create() {
        appState.createTagDefinition(name: newTag)
        newTag = ""
    }

    private func usageCount(for name: String) -> Int {
        appState.analytics?.segments.filter {
            $0.tags.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame })
        }.count ?? 0
    }
}

extension Color {
    init?(hex: String) {
        var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("#") { cleaned.removeFirst() }
        guard cleaned.count == 6 || cleaned.count == 8 else { return nil }
        var value: UInt64 = 0
        guard Scanner(string: cleaned).scanHexInt64(&value) else { return nil }
        let r, g, b, a: Double
        if cleaned.count == 8 {
            a = Double((value & 0xFF00_0000) >> 24) / 255
            r = Double((value & 0x00FF_0000) >> 16) / 255
            g = Double((value & 0x0000_FF00) >> 8) / 255
            b = Double(value & 0x0000_00FF) / 255
        } else {
            a = 1
            r = Double((value & 0xFF0000) >> 16) / 255
            g = Double((value & 0x00FF00) >> 8) / 255
            b = Double(value & 0x0000FF) / 255
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
