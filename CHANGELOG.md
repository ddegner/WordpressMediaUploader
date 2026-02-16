# Changelog

All notable changes to this project are documented in this file.

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
