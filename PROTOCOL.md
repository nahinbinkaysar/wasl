# Wasl protocol

## Pairing
The Mac generates a 32-byte random key on first launch. Share it with the phone once (Copy pairing key → paste).
Everything below is encrypted with that key, so neither the LAN nor the relay sees plaintext.

## Transport
- **LAN:** the Mac advertises `_wasl._tcp` via Bonjour and accepts WebSocket connections. The phone discovers it with NSD.
- **Relay:** both sides connect to `wss://<relay>/ws?room=<room>&token=<invite>`.
  `room` = first 32 hex chars of `SHA256("wasl-room" + key)`. The relay forwards binary frames to the other sockets in the same room.

## Frames
Each WebSocket binary message = `nonce (12 bytes) || AES-256-GCM ciphertext || tag (16 bytes)`.
A frame that fails to decrypt closes the connection.

Plaintext is UTF-8 JSON with a `t` (type) field:

| t | fields | direction |
|---|---|---|
| `clip` | `text` | both |
| `notif` | `id`, `app`, `title`, `text`, `time` (ms since epoch) | phone → Mac, posted or updated |
| `notifs` | `items`: list of `notif` objects | phone → Mac, full list on connect |
| `notif_removed` | `id` | phone → Mac |
| `dismiss` | `id` | Mac → phone, cleared on the Mac |

Unknown types are ignored, so new clients and old clients can talk to each other.
