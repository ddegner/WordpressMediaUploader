# Privacy Policy

Effective date: 2026-02-16

This privacy policy describes how WP Media Uploader ("the app") handles information.

WP Media Uploader is an independent, open source macOS app that helps you upload media to your own WordPress site using SSH, rsync, and WP-CLI.

## What The App Stores

The app stores the following data on your Mac:

- Server profile details you enter (for example: host, username, port, WordPress path, staging options).
- Job history, logs, and report files created during uploads.
- App settings.

These are stored in your local user data folder (for example, `~/Library/Application Support/WPMediaUploader/`).

## Credentials

- Passwords and SSH key passphrases are stored in the macOS Keychain.
- Credentials are used only to authenticate to the server(s) you configure.

## Network Use

The app connects only to destinations required for its function:

- Your configured server(s), over SSH/rsync, to upload files and run WordPress import commands.

The app does not include advertising SDKs and does not send analytics or tracking data to third-party analytics services.

## Data Sharing

The developer does not receive your server credentials, uploaded files, or job data.

Your data is transmitted to your own server infrastructure as directed by you.

## Data Retention And Deletion

- Local app data remains on your device until you delete profiles/data or remove the app data directory.
- Keychain items remain until removed by deleting related profiles in the app or by deleting items in Keychain Access.
- Uploaded media on remote servers is controlled by your server and WordPress configuration.

## Third-Party Platforms

If you download the app through Apple platforms, Apple may process data according to Apple's own policies. This policy covers the app itself.

## Contact

For privacy questions, open an issue at:

https://github.com/ddegner/WPMediaUploader/issues
