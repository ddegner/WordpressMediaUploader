# WP Media Uploader

[Download macOS binary (v1.0)](https://github.com/ddegner/WPMediaUploader/raw/main/WPMediaUploader-v1.0-macOS.zip)

WordPress media uploader for macOS.
An independent, open source macOS app to upload media to WordPress sites.

Designed for speed and reliability, it uses `rsync`, `ssh`, and `wp-cli` to handle large media libraries efficiently.

**Version 1.0** · macOS 14+

[Privacy Policy](PRIVACY.md)

## Screenshots

Quick visual tour of the app workflow:

- **Overview** — three-pane workspace with profiles, drop zone, and operations drawer.
![Overview](screenshots/01-overview.png)

- **Queue + job status** — queued files, per-file state, and active job progress in one view.
![Queued files](screenshots/02-queued-files.png)

- **Profile setup** — complete connection and WordPress settings in the built-in profile editor.
![Profile editor](screenshots/03-profile-editor.png)

## Features

- **Single-window profile setup** — connection, WordPress path, import defaults
- **Multiple server profiles**
- **Credentials stored in Keychain** — password auth and optional key passphrase
- **SSH auth modes** — key-based (agent-friendly) or password via `SSH_ASKPASS`
- **Drag-and-drop & file picker** — JPG, JPEG, JPE, GIF, PNG, BMP, ICO, WebP, AVIF, HEIC, PDF
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
open "WordpressMediaUploader.xcodeproj"
```

## Distribution (Signed + Notarized)

Use the release script (this is the default distribution path):

```bash
./scripts/build_distribution.sh
```

Credentials for notarization:

- Preferred: set `NOTARY_KEYCHAIN_PROFILE` to a notarytool keychain profile name.
- Alternative: set `APPLE_ID`, `APPLE_TEAM_ID`, and `APPLE_APP_SPECIFIC_PASSWORD`.

The script will:

- Build a Release app
- Sign with Developer ID (`DEVELOPER_ID_APP_CERT`, defaults to this repo's Developer ID cert)
- Submit for notarization and wait for acceptance
- Staple the notarization ticket
- Produce `WPMediaUploader-v<version>-macOS.zip`
- Send a macOS notification on success/failure

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
- Job and profile data are saved under `~/Library/Application Support/WPMediaUploader/`
- Passwords and key passphrases are stored in the macOS Keychain

## License

MIT
