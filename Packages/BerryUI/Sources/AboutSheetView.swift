import AppKit
import SwiftUI

public struct AboutSheetView: View {
    @Environment(\.dismiss) private var dismiss
    private let checkForUpdates: () -> Void

    public init(checkForUpdates: @escaping () -> Void = {}) {
        self.checkForUpdates = checkForUpdates
    }

    /// Real bundle version — `Bundle.main.infoDictionary` is unpopulated
    /// under `swift run`/tests (no `.app` bundle), hence the placeholder
    /// fallback rather than a fake version number.
    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        guard let short, let build else { return L("Unknown") }
        return "\(short) (Build \(build))"
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Header with Icon & Title
            HStack(spacing: 16) {
                if let image = loadAppIcon() {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 64, height: 64)
                        .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
                } else {
                    Image(systemName: "cylinder.split.1x2.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(BerryTheme.accent)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("BerryDB")
                        .font(.system(size: 22, weight: .bold))
                    Text(L("Fast, Native Database Client for macOS"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                // Section 1: BerryDB Information
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("BerryDB Information"))
                        .font(.system(size: 13, weight: .bold))

                    HStack(spacing: 6) {
                        Text("•").foregroundStyle(.secondary)
                        Text(L("Version:"))
                            .fontWeight(.medium)
                        Text(versionString)
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 12))

                    HStack(spacing: 6) {
                        Text("•").foregroundStyle(.secondary)
                        Text(L("Updates:"))
                            .fontWeight(.medium)
                        Button {
                            checkForUpdates()
                        } label: {
                            Text(L("Check for Updates…"))
                                .foregroundStyle(BerryTheme.accent)
                        }
                        .buttonStyle(.plain)
                        .focusable(false)
                        .focusEffectDisabled()
                    }
                    .font(.system(size: 12))
                }

                // Section 2: Description
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Description"))
                        .font(.system(size: 13, weight: .bold))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(L("BerryDB is a fast, minimal macOS database client."))
                        Text(L("Manage, query, and explore your databases with zero friction."))
                        Text(L("Built for speed and simplicity."))
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                }

                // Section 3: Links
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Links"))
                        .font(.system(size: 13, weight: .bold))

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text("•").foregroundStyle(.secondary)
                            Text(L("Website:"))
                                .fontWeight(.medium)
                            Button {
                                if let url = URL(string: "https://db.berryhub.app") {
                                    NSWorkspace.shared.open(url)
                                }
                            } label: {
                                Text("https://db.berryhub.app")
                                    .foregroundStyle(BerryTheme.accent)
                            }
                            .buttonStyle(.plain)
                            .focusable(false)
                            .focusEffectDisabled()
                        }

                        HStack(spacing: 6) {
                            Text("•").foregroundStyle(.secondary)
                            Text(L("Support:"))
                                .fontWeight(.medium)
                            Button {
                                if let url = URL(string: "mailto:info@berryhub.app") {
                                    NSWorkspace.shared.open(url)
                                }
                            } label: {
                                Text("info@berryhub.app")
                                    .foregroundStyle(BerryTheme.accent)
                            }
                            .buttonStyle(.plain)
                            .focusable(false)
                            .focusEffectDisabled()
                        }

                        HStack(spacing: 6) {
                            Text("•").foregroundStyle(.secondary)
                            Text(L("Telegram:"))
                                .fontWeight(.medium)
                            Button {
                                if let url = URL(string: "https://t.me/berryecosystem") {
                                    NSWorkspace.shared.open(url)
                                }
                            } label: {
                                Text("t.me/berryecosystem")
                                    .foregroundStyle(BerryTheme.accent)
                            }
                            .buttonStyle(.plain)
                            .focusable(false)
                            .focusEffectDisabled()
                        }
                    }
                    .font(.system(size: 12))
                }
            }

            Divider()

            HStack {
                Text("Copyright © 2026 BerryHub. All rights reserved.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button(L("Close")) {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .focusable(false)
                .focusEffectDisabled()
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 24)
        .frame(width: 450, height: 452)
        .focusable(false)
        .focusEffectDisabled()
    }

    private func loadAppIcon() -> NSImage? {
        if let image = NSApp.applicationIconImage {
            return image
        }
        return nil
    }
}
