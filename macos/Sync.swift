import AppKit
import CryptoKit
import Network
import Observation

// ponytail: everything runs on the main queue; traffic is a few small frames, no need for more.
@Observable final class Sync {
    private(set) var peers = 0
    private(set) var relayUp = false
    let key = Keychain.pairingKey()

    private var conns: [NWConnection] = [] { didSet { peers = conns.count } }
    private var listener: NWListener?
    private var relay: NWConnection?
    private var lastChange = NSPasteboard.general.changeCount

    init() {
        startListener()
        connectRelay()
        // NSPasteboard has no change event; polling changeCount is what every clipboard app does.
        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in self?.pollClipboard() }
    }

    var pairingCode: String { key.withUnsafeBytes { Data($0) }.base64EncodedString() }

    var room: String {
        let digest = SHA256.hash(data: Data("wasl-room".utf8) + key.withUnsafeBytes { Data($0) })
        return digest.map { String(format: "%02x", $0) }.joined().prefix(32).description
    }

    // MARK: LAN

    private func startListener() {
        guard let l = try? NWListener(using: Self.wsParams(tls: false)) else { return }
        l.service = NWListener.Service(name: Host.current().localizedName, type: "_wasl._tcp")
        l.newConnectionHandler = { [weak self] c in
            guard let self else { return }
            c.stateUpdateHandler = { [weak self, weak c] state in
                guard let self, let c else { return }
                if case .failed = state { c.cancel() }
                if case .cancelled = state { self.conns.removeAll { $0 === c } }
            }
            conns.append(c)
            c.start(queue: .main)
            receive(c)
        }
        l.start(queue: .main)
        listener = l
    }

    // MARK: Relay

    func connectRelay() {
        let old = relay
        relay = nil
        old?.cancel()
        relayUp = false
        let d = UserDefaults.standard
        guard let base = d.string(forKey: "relayURL"), let token = d.string(forKey: "relayToken"),
              !base.isEmpty, var url = URLComponents(string: base) else { return }
        url.path = "/ws"
        url.queryItems = [.init(name: "room", value: room), .init(name: "token", value: token)]
        guard let u = url.url else { return }

        let c = NWConnection(to: .url(u), using: Self.wsParams(tls: u.scheme == "wss"))
        relay = c
        c.stateUpdateHandler = { [weak self, weak c] state in
            guard let self, let c, c === self.relay else { return }
            switch state {
            case .ready: relayUp = true
            case .failed: c.cancel()
            case .cancelled:
                relayUp = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    if self?.relay === c { self?.connectRelay() }
                }
            default: break
            }
        }
        c.start(queue: .main)
        receive(c)
    }

    // MARK: Frames

    private func receive(_ c: NWConnection) {
        c.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty, !handle(data) { c.cancel(); return }
            if error == nil { receive(c) } else { c.cancel() }
        }
    }

    /// Returns false when the frame isn't ours (wrong key / tampered).
    private func handle(_ frame: Data) -> Bool {
        guard let box = try? AES.GCM.SealedBox(combined: frame),
              let plain = try? AES.GCM.open(box, using: key) else { return false }
        guard let msg = try? JSONSerialization.jsonObject(with: plain) as? [String: Any] else { return true }
        if msg["t"] as? String == "clip", let text = msg["text"] as? String {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
            lastChange = pb.changeCount
        }
        return true
    }

    private func broadcast(_ msg: [String: String]) {
        guard let plain = try? JSONSerialization.data(withJSONObject: msg),
              let frame = try? AES.GCM.seal(plain, using: key).combined else { return }
        let ctx = NWConnection.ContentContext(identifier: "frame",
                                              metadata: [NWProtocolWebSocket.Metadata(opcode: .binary)])
        for c in conns + [relay].compactMap({ $0 }) {
            c.send(content: frame, contentContext: ctx, isComplete: true, completion: .idempotent)
        }
    }

    // MARK: Clipboard

    private func pollClipboard() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount
        // Password managers mark secrets as concealed/transient (nspasteboard.org); never sync those.
        let types = Set(pb.types?.map(\.rawValue) ?? [])
        guard types.isDisjoint(with: ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"]),
              let text = pb.string(forType: .string) else { return }
        broadcast(["t": "clip", "text": text])
    }

    func copyPairingCode() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(pairingCode, forType: .string)
        pb.setString("", forType: .init("org.nspasteboard.ConcealedType"))
    }

    private static func wsParams(tls: Bool) -> NWParameters {
        let params: NWParameters = tls ? .tls : .tcp
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = 1 << 20
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        return params
    }
}

enum Keychain {
    static func pairingKey() -> SymmetricKey {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: "wasl",
                                    kSecAttrAccount as String: "pairing-key"]
        var out: CFTypeRef?
        let lookup = query.merging([kSecReturnData as String: true]) { $1 }
        if SecItemCopyMatching(lookup as CFDictionary, &out) == errSecSuccess, let data = out as? Data {
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        SecItemAdd(query.merging([kSecValueData as String: key.withUnsafeBytes { Data($0) }]) { $1 } as CFDictionary, nil)
        return key
    }
}
