# Wasl

Native Mac ⇄ Android link: clipboard sync for now, with notifications and messages next.
The two devices talk directly over the LAN, or through an optional self-hosted relay when they're apart.
Every frame is end-to-end encrypted with a key that never leaves your devices. See [PROTOCOL.md](PROTOCOL.md).

| | |
|---|---|
| `macos/` | Swift + SwiftUI menu bar app |
| `android/` | Kotlin app with a foreground service |
| `relay/` | Go relay; forwards ciphertext only |

## Mac

```sh
macos/bundle.sh && open macos/build/Wasl.app
```

## Android

Build with Android Studio, or run `./gradlew installDebug` in `android/`. Then pair:

```sh
adb shell am start -n dev.wasl/.MainActivity --es key "<paste from Mac menu → Copy pairing key>"
```

Tap **Save & start**. For background clipboard reads (the same trick KDE Connect uses), run once:

```sh
adb shell pm grant dev.wasl android.permission.READ_LOGS
adb shell appops set dev.wasl SYSTEM_ALERT_WINDOW allow
```

Android 13+ asks "allow access to device logs" each time the service starts.

## Relay (optional, for when you're away from home)

Access is invite-only: each person gets a token.

```sh
docker build -t wasl-relay relay
docker run -d --restart=always -p 127.0.0.1:8080:8080 -e WASL_TOKENS=alice-xxxx,bob-yyyy wasl-relay
```

Put TLS in front of it, for example with a Caddyfile line `relay.example.com { reverse_proxy 127.0.0.1:8080 }`.
Then set `wss://relay.example.com` and your token in the Mac's Relay settings and in the Android app.

## License

GPL-3.0. See [LICENSE](LICENSE).
