# Changelog

All notable changes to this project are documented in this file.

## [Unreleased]

### Changed
- `scripts/build_distribution.sh` now publishes a GitHub Release by default: it ensures `v<version>` tag alignment with `HEAD`, pushes the tag to `origin`, and creates/updates the release with `WPMediaUploader-v<version>-macOS.zip` plus `sha256.txt`.
- `scripts/build_distribution.sh` now defaults `NOTARY_KEYCHAIN_PROFILE` to `notary-profile` (still overrideable via env).
- Starting an upload no longer forces the operations drawer open; if the drawer is hidden, it remains hidden.
- Queue row status now shows `PREFLIGHT` during preflight, uses an in-progress spinner for preflight rows, and aligns preflight hover text with active preflight processing.

### Added
- GitHub Actions release automation at `.github/workflows/release-package.yml` to build/sign/notarize/staple on tag pushes, publish GitHub Release assets, and publish a GHCR package containing the release zip + checksum.
- `scripts/app_store_resubmit.sh` to update App Store metadata and submit versions for review, with explicit credential/version inputs and `umask 077`.
- `APP_STORE_CONNECT_SUBMISSION_RUNBOOK.md` and `APP_STORE_METADATA.md` for repeatable App Store Connect submission and metadata remediation steps.

### Security
- Transient `SSH_ASKPASS` scripts now use a locked system temp directory with restrictive permissions and backup exclusion, while preserving stale script cleanup for legacy app-support locations.
- Release workflow now explicitly cleans imported signing credentials (temporary keychain and `.p12`) at job end.

## [1.0] - 2026-02-17

### Added
- Icon-only operations tab selector with larger hit targets and full-width layout in the right drawer.
- New `scripts/build_distribution.sh` release workflow that signs with Developer ID, notarizes, staples, and sends a completion notification.

### Changed
- Unified Active Job, Terminal, and Job History empty-state presentation with centered messaging and consistent drawer styling.
- Updated operations tab icon mapping (Active Job now uses `hourglass` instead of a play glyph).
- Bumped app version to `1.0` and build number to `4`.
- Updated README download/version references for the `v1.0` release artifact.
- Published `WPMediaUploader-v1.0-macOS.zip` as a Developer ID signed and notarized macOS binary.

### Fixed
- Reduced excess top spacing in the right operations drawer header area for better visual balance.

## [0.9] - 2026-02-16

### Added
- Per-file `imported` progress state in the queue UI to clearly separate import completion from thumbnail regeneration completion.
- Richer file status help text for uploaded, verified, imported, regenerated, and failed states.

### Changed
- Job status labels now render with title-cased step text for improved readability.
- Profile connection test action now shows its progress indicator in the profile editor row where the test is initiated.
- Published `WPMediaUploader-v0.9-macOS.zip` as a Developer ID signed and notarized macOS binary.

### Fixed
- Import loop now regenerates thumbnails immediately after each successful WordPress import.
- Import progress updates are now applied consistently via shared progress update handling.
- Regeneration failures now emit timeout-aware error messages and preserve clear per-file failure context.

## [0.8] - 2026-02-16

### Added
- New macOS App Store asset set under `screenshots/app-store/macos/` in 1280x800, 2560x1600, and 2880x1800 variants.
- App Store icon export at `screenshots/app-store/macos/app-icon/app-icon-1024.png`.

### Changed
- App display/product name now uses `WP Media Uploader`.
- Updated release copy and metadata strings to match the new branding and macOS-focused description.
- Refreshed README screenshots and `app-screenshot.png` captures from the latest app build.
- Updated project marketing version to `0.8` and build number to `2`.

## [0.7] - 2026-02-14

### Added
- Completion sound toggle in app commands (`Play Sound on Completion`).
- Focused drawer command bindings for profile and operations drawers.
- Refined operations drawer tab control with icon-based segmented control.
- Expanded README screenshots for overview, queue status, and profile setup.

### Changed
- Updated app icon set assets.
- Updated app version to `0.7`.
- Refined content layout and actions in the main workbench UI.
- Profile selection is now handled in `ContentView` UI state.
- `CommandRunner` output collection now emits lines outside the lock to avoid callback re-entry while locked.
- `LogWriter` now computes timestamp/payload within its serialization queue.

### Fixed
- Interrupted jobs are preserved and recoverable instead of being removed during store initialization.
- Regeneration step now targets only successfully imported items for retry correctness.
- Retry progress calculation now reflects already-processed files before re-running failed work.
- In-flight job recovery now always marks interrupted pipeline jobs as failed with a clear reason.

## [0.6] - 2026-02-14
- Prior release baseline (`v0.6` tag).

## [0.5] - 2026-02-13
- First tagged release (`v0.5` tag).
