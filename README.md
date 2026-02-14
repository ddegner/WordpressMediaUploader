# Wordpress Media Uploader

A native macOS app built in SwiftUI for batch-uploading images to a remote WordPress server.

Designed for speed and reliability, it uses `rsync`, `ssh`, and `wp-cli` to handle large media libraries efficiently.

**Version 0.5** · macOS 14+

## Features

- **Single-window profile setup** — connection, WordPress path, import defaults
- **Multiple server profiles** with persistent selection
- **Credentials stored in Keychain** — password auth and optional key passphrase
- **SSH auth modes** — key-based (agent-friendly) or password via `SSH_ASKPASS`
- **Drag-and-drop & file picker** — JPG, PNG, WebP, TIFF, AVIF
- **Reliable job pipeline** — preflight → upload (`rsync`) → verify → import (`wp media import`) → regenerate thumbnails → cleanup
- **Retry failed files** without reprocessing successful ones
- **Streaming logs** in-app + persisted log files
- **Reports** — copy text, export JSON or CSV

## Requirements

- macOS 14 (Sonoma) or later
- Xcode 16+ (to build from source)
- SSH access to target server
- `wp-cli` installed on the remote server
- WordPress installation on the remote server

## Build

```bash
swift build
```

## Test

```bash
swift test
```

## Run

```bash
swift run WordpressMediaUploaderApp
```

Or open the Xcode project and run from there:

```bash
xcodegen generate
open "Wordpress Media Uploader.xcodeproj"
```

## How It Works

1. **Create a server profile** with your SSH credentials and WordPress root path
2. **Drop images** onto the app (or use Browse)
3. **Click Upload** — the app will:
   - Verify SSH connectivity and `wp-cli` availability
   - Upload files via `rsync` with progress tracking
   - Verify remote file integrity (size check)
   - Import each file into WordPress media library
   - Regenerate thumbnails
   - Optionally clean up remote staging files

## Notes

- Default staging path is `~/wp-media-import`
- Job and profile data are saved under `~/Library/Application Support/WordpressMediaUploader/`
- Passwords and key passphrases are stored in the macOS Keychain

## License

MIT
