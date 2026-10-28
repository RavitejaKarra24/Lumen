import SwiftUI

struct MetricCard: View {
    let title: String
    let value: String
    var subtitle: String? = nil
    var symbol: String? = nil
    var accent: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.6)
                Spacer()
                if let symbol {
                    Image(systemName: symbol)
                        .foregroundStyle(accent)
                }
            }
            Text(value)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .contentTransition(.numericText())
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        }
    }
}

struct UsageBarRow: View {
    let title: String
    let subtitle: String?
    let duration: TimeInterval
    let total: TimeInterval
    var symbol: String = "circle.fill"
    var color: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: symbol)
                    .foregroundStyle(color)
                    .frame(width: 16)
                Text(title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Spacer()
                Text(DurationFormat.compact(duration))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 28)
            }
            GeometryReader { geo in
                let ratio = total > 0 ? min(1, duration / total) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.06))
                    Capsule()
                        .fill(color.gradient)
                        .frame(width: max(4, geo.size.width * ratio))
                }
            }
            .frame(height: 6)
            .padding(.leading, 28)
        }
        .padding(.vertical, 6)
    }
}

struct DayPickerBar: View {
    @Binding var day: Date
    var onChange: (Date) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button {
                shift(-1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)

            DatePicker(
                "",
                selection: Binding(
                    get: { day },
                    set: { newValue in
                        day = newValue
                        onChange(newValue)
                    }
                ),
                displayedComponents: .date
            )
            .datePickerStyle(.field)
            .labelsHidden()

            Button {
                shift(1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.borderless)
            .disabled(Calendar.current.isDateInToday(day))

            if !Calendar.current.isDateInToday(day) {
                Button("Today") {
                    day = .now
                    onChange(.now)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private func shift(_ days: Int) {
        if let next = Calendar.current.date(byAdding: .day, value: days, to: day) {
            if days > 0, next > Date.now { return }
            day = next
            onChange(next)
        }
    }
}

struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: () -> Void = {}

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title2.weight(.semibold))
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            if let actionTitle {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

struct CategoryBadge: View {
    let category: ActivityCategory

    var body: some View {
        Label(category.displayName, systemImage: category.symbolName)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(category.color.opacity(0.15), in: Capsule())
            .foregroundStyle(category.color)
    }
}

struct SessionKindBadge: View {
    let kind: SessionKind

    var body: some View {
        Label(kind.displayName, systemImage: kind.symbolName)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(kind.color.opacity(0.15), in: Capsule())
            .foregroundStyle(kind.color)
    }
}

struct FocusRing: View {
    let score: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.08), lineWidth: 10)
            Circle()
                .trim(from: 0, to: score / 100)
                .stroke(
                    AngularGradient(
                        colors: [.orange, .yellow, .green, .orange],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 10, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            VStack(spacing: 2) {
                Text("\(Int(score.rounded()))")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                Text("focus")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 120, height: 120)
    }
}

extension ActivityCategory {
    var color: Color {
        switch self {
        case .coding: .blue
        case .browsing: .cyan
        case .communication: .green
        case .design: .purple
        case .media: .pink
        case .productivity: .orange
        case .system: .gray
        case .entertainment: .red
        case .learning: .indigo
        case .other: .secondary
        }
    }
}
