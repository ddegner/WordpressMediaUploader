# App Store Metadata Fix (Guideline 5.2.5)

This app was rejected on February 18, 2026 under Guideline 5.2.5 (Legal - Intellectual Property) for subtitle wording:

- Rejected subtitle: `Fast WordPress uploads on Mac`

## Use This Subtitle

- New subtitle: `Bulk WordPress Media Uploads`

This keeps the subtitle descriptive and avoids Apple trademark terms in the subtitle.

## Suggested Metadata Updates (en-US)

- App Name: `WP Media Uploader`
- Subtitle: `Bulk WordPress Media Uploads`
- Keywords (updated): `wordpress,wp-cli,media uploader,ssh,rsync,bulk upload,images,photos,blogging`

## App Store Connect Update Steps

1. Open App Store Connect -> My Apps -> `WP Media Uploader`.
2. Open **App Information**.
3. For `en-US`, replace Subtitle with `Bulk WordPress Media Uploads`.
4. Save.
5. Re-submit the version for review.

## API Automation

You can apply the subtitle fix and trigger re-submission via script:

```bash
ASC_KEY_ID=<your-key-id> \
ASC_ISSUER_ID=<your-issuer-id> \
VERSION_STRING=<version> \
./scripts/app_store_resubmit.sh
```

## Suggested Reply To App Review

We updated the app metadata to remove Apple trademark wording from the subtitle.  
Specifically, we changed the subtitle from "Fast WordPress uploads on Mac" to "Bulk WordPress Media Uploads" and resubmitted the app for review.
