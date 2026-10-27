import SwiftUI

// One instance for the app's lifetime (also avoids @State, a macro the Command Line Tools can't expand on macOS 27).
private let sync = Sync()
private let panel = PanelState()

@Observable final class PanelState {
    var expanded: String?
}

@main
struct WaslApp: App {
    var body: some Scene {
        MenuBarExtra {
            Panel(sync: sync, state: panel)
        } label: {
            Image(systemName: sync.peers > 0 || sync.relayUp ? "link.circle.fill" : "link.circle")
            if !sync.phoneNotifs.isEmpty { Text("\(sync.phoneNotifs.count)") }
        }
        .menuBarExtraStyle(.window)

        Settings {
            RelaySettings(sync: sync)
        }
    }
}

private struct Panel: View {
    let sync: Sync
    let state: PanelState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Phone notifications").font(.headline)
                Spacer()
                Text(sync.peers > 0 ? "LAN" : sync.relayUp ? "Relay" : "Offline")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(12)
            Divider()

            if sync.phoneNotifs.isEmpty {
                ContentUnavailableView("No notifications", systemImage: "bell.slash")
                    .frame(height: 160)
            } else {
                // Grows with the list, scrolls past 440pt.
                ViewThatFits(in: .vertical) {
                    rows
                    ScrollView { rows }
                }
                .frame(maxHeight: 440)
            }

            Divider()
            HStack {
                Button("Clear all") { sync.clearAll() }
                    .disabled(sync.phoneNotifs.isEmpty)
                Spacer()
                Menu {
                    Button("Copy pairing key") { sync.copyPairingCode() }
                    Button("Relay settings…") {
                        NSApp.activate()
                        openSettings()
                    }
                    Divider()
                    Button("Quit Wasl") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(10)
        }
        .frame(width: 360)
    }

    private var rows: some View {
        LazyVStack(spacing: 0) {
            ForEach(sync.phoneNotifs) { n in
                Row(n: n, expanded: state.expanded == n.id,
                    toggle: { state.expanded = state.expanded == n.id ? nil : n.id },
                    clear: { sync.clear(n.id) })
                Divider()
            }
        }
    }
}

private struct Row: View {
    let n: PhoneNotif
    let expanded: Bool
    let toggle: () -> Void
    let clear: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(n.app)
                    Spacer()
                    Text(n.time, format: .relative(presentation: .named))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if !n.title.isEmpty {
                    Text(n.title).font(.body.weight(.semibold)).lineLimit(expanded ? nil : 1)
                }
                if !n.text.isEmpty {
                    Text(n.text).font(.callout).lineLimit(expanded ? nil : 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: toggle)

            Button(action: clear) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Clear on phone and Mac")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct RelaySettings: View {
    let sync: Sync
    @AppStorage("relayURL") private var relayURL = ""
    @AppStorage("relayToken") private var relayToken = ""

    var body: some View {
        Form {
            TextField("Relay URL", text: $relayURL, prompt: Text("wss://relay.example.com"))
            SecureField("Invite token", text: $relayToken)
            Button("Connect") { sync.connectRelay() }
        }
        .padding()
        .frame(width: 380)
    }
}
