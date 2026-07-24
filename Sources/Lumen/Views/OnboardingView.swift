import SwiftUI

struct OnboardingView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                VStack(spacing: 20) {
                    Image(systemName: "sun.max.circle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.orange.gradient)
                        .symbolRenderingMode(.hierarchical)

                    Text("Welcome to Lumen")
                        .font(.largeTitle.weight(.semibold))

                    Text("Automatic time tracking for your Mac — apps, websites, focus, and daily reports.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 440)

                    VStack(alignment: .leading, spacing: 14) {
                        featureRow(
                            symbol: "app.badge.checkmark",
                            title: "App & window tracking",
                            subtitle: "Know exactly where your attention went."
                        )
                        featureRow(
                            symbol: "globe",
                            title: "Website visits",
                            subtitle: "Safari, Chrome, Arc, Brave, Edge, Firefox and more."
                        )
                        featureRow(
                            symbol: "doc.richtext",
                            title: "Daily Markdown reports",
                            subtitle: "Export a clean summary every day."
                        )
                    }
                    .padding(.top, 8)

                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Accessibility permission required", systemImage: "hand.raised.fill")
                                .font(.headline)
                            Text("Lumen reads the frontmost app title and browser URL through macOS Accessibility. Nothing is uploaded — data stays on this Mac.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            HStack {
                                Button("Open Accessibility Settings") {
                                    appState.permissions.requestAccessibility()
                                }
                                .buttonStyle(.borderedProminent)

                                if appState.permissions.hasAccessibility {
                                    Label("Granted", systemImage: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                        .font(.callout.weight(.medium))
                                } else {
                                    Button("I’ve granted access") {
                                        appState.permissions.refresh()
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                    }
                    .frame(maxWidth: 480)
                }
                .padding(36)

                Divider()

                HStack {
                    Text("Goalpost 1 · Recorder")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button("Start tracking") {
                        appState.completeOnboarding()
                        appState.startRecordingIfPossible()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                }
                .padding(20)
            }
            .frame(width: 560)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 40, y: 16)
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            }
        }
    }

    private func featureRow(symbol: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.orange)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 440, alignment: .leading)
    }
}
