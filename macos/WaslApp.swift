import SwiftUI

// One instance for the app's lifetime (also avoids @State, a macro the Command Line Tools can't expand on macOS 27).
private let sync = Sync()

@main
struct WaslApp: App {

    var body: some Scene {
        MenuBarExtra("Wasl", systemImage: sync.peers > 0 || sync.relayUp ? "link.circle.fill" : "link.circle") {
            Menu(sync: sync)
        }
        Settings {
            RelaySettings(sync: sync)
        }
    }
}

private struct Menu: View {
    let sync: Sync
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text("Phones on LAN: \(sync.peers)")
        Text(sync.relayUp ? "Relay: connected" : "Relay: off")
        Divider()
        Button("Copy pairing key") { sync.copyPairingCode() }
        Button("Relay settings…") {
            NSApp.activate()
            openSettings()
        }
        Divider()
        Button("Quit Wasl") { NSApp.terminate(nil) }.keyboardShortcut("q")
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
