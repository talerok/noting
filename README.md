# Noting

A privacy-focused notes app for macOS and iOS with end-to-end encryption and Dropbox sync.

## Features

- **Cross-platform** — native SwiftUI app for macOS and iOS
- **Dropbox sync** — manifest-based sync with conflict resolution and soft-delete tombstones
- **Per-note encryption** — AES-GCM with PBKDF2 key derivation (100k iterations)
- **Search** — real-time full-text filtering
- **Pin notes** — keep important notes at the top
- **Autotype (macOS)** — global hotkey to quickly paste note content into any app via a floating panel
- **Run in Terminal / Open in Browser (macOS)** — execute selected text or open URLs directly from the editor
- **Appearance** — light, dark, and system modes

## Tech Stack

- Swift 6 / SwiftUI 6
- SwiftData for local persistence
- CryptoKit + CommonCrypto for encryption
- Dropbox API v2 with OAuth 2.0 PKCE
- Keychain for secure token storage

## Building

Open `Noting.xcodeproj` in Xcode 26+ and build for the desired target (macOS 26+ / iOS 26+).

## License

[MIT](LICENSE)
