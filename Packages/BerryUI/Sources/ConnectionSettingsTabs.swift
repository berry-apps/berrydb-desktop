import SwiftUI

enum ConnectionSettingsTab: CaseIterable {
    case general, advanced, tls, ssh

    var title: String {
        switch self {
        case .general: L("General")
        case .advanced: L("Advanced")
        case .tls: L("TLS")
        case .ssh: L("SSH Tunnel")
        }
    }
}

struct ConnectionSettingsTabs: View {
    @Binding var selection: ConnectionSettingsTab
    let includesNetwork: Bool

    var body: some View {
        Picker(L("Connection settings"), selection: $selection) {
            ForEach(ConnectionSettingsTab.allCases.filter {
                includesNetwork || $0 == .general || $0 == .advanced
            }, id: \.self) { tab in
                Text(tab.title).tag(tab)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .fixedSize(horizontal: true, vertical: false)
        .padding(10)
        .frame(maxWidth: .infinity)
    }
}
