# App Store Connect Submission Runbook (iOS + macOS)

Last verified: February 20, 2026.

Use this runbook when a new version is already uploaded to App Store Connect and you want to submit it for review.

## Scope

1. Platform targets: `IOS` and `MAC_OS`.
2. Release mode: `AFTER_APPROVAL` (automatic release after approval).
3. API workflow: `reviewSubmissions` + `reviewSubmissionItems`.

## Known Working Auth Setup

The credential source that currently works is Keychain-backed:

1. `ASC_KEY_ID_CATSCRATCHES`
2. `ASC_ISSUER_ID_CATSCRATCHES`
3. `ASC_AUTHSTRING_2FCY9973VV`

The matching private key file must also exist:

1. `~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8`

Notes:

1. Existing local key files can return `401 NOT_AUTHORIZED` if the issuer/key pair is wrong.
2. This credential set has verified access to both apps:
   - `6749605278` (`Cat Scratches`)
   - `6759262491` (`WP Media Uploader`)

## Load Credentials From Keychain

```bash
KEY_ID="$(security find-generic-password -a "$USER" -s ASC_KEY_ID_CATSCRATCHES -w)"
ISSUER_ID="$(security find-generic-password -a "$USER" -s ASC_ISSUER_ID_CATSCRATCHES -w)"
AUTH_STRING="$(security find-generic-password -a "$USER" -s ASC_AUTHSTRING_2FCY9973VV -w)"
```

## Read-Only Auth Check (Do This First)

```bash
TOKEN="$(
  xcrun altool --generate-jwt \
    --apiKey "$KEY_ID" \
    --apiIssuer "$ISSUER_ID" \
    --auth-string "$AUTH_STRING" 2>&1 \
    | rg -o '[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+' \
    | tail -n1
)"

curl -sS \
  -H "Authorization: Bearer $TOKEN" \
  "https://api.appstoreconnect.apple.com/v1/apps/6759262491" | jq .
```

Expected:

1. HTTP success with app payload.
2. App name should be `WP Media Uploader` for app id `6759262491`.

## Fast WP Media Uploader Resubmission (Metadata + Submit)

Use the repo script:

```bash
APP_ID=6759262491 \
VERSION_STRING="<version>" \
PLATFORM=MAC_OS \
ASC_KEY_ID="$KEY_ID" \
ASC_ISSUER_ID="$ISSUER_ID" \
API_PRIVATE_KEYS_DIR="$HOME/.appstoreconnect/private_keys" \
./scripts/app_store_resubmit.sh
```

Defaults inside script (if not overridden):

1. `NEW_SUBTITLE="Bulk WordPress Media Uploads"`
2. `NEW_KEYWORDS="wordpress,wp-cli,media uploader,ssh,rsync,bulk upload,images,photos,blogging"`

## Full Submission Flow (iOS + macOS)

Prerequisites:

1. Upload both builds first.
2. Confirm both builds are `VALID` in App Store Connect.

Required release inputs:

1. `APP_ID` (`6749605278` or `6759262491`).
2. `VERSION_STRING` (example: `2.1.0`).
3. `IOS_BUILD_ID` and `MAC_BUILD_ID`.
4. Optional `WHATS_NEW_TEXT` (`en-US`).

Submission flow:

1. List or create `appStoreVersions` for `IOS` and `MAC_OS`.
2. Patch each `appStoreVersion` to `releaseType: AFTER_APPROVAL`.
3. Attach each build with `PATCH /v1/appStoreVersions/{id}/relationships/build`.
4. Patch encryption on each build with `usesNonExemptEncryption=false`.
5. Ensure `en-US` localization exists and set `whatsNew`.
6. Create `reviewSubmissions` (one per platform).
7. Create `reviewSubmissionItems` for each platform version.
8. Submit each review submission with `submitted=true`.
9. Verify `appStoreState=WAITING_FOR_REVIEW` and `releaseType=AFTER_APPROVAL`.

## Minimal Endpoint Reference

1. `GET /v1/apps/{appId}/appStoreVersions`
2. `POST /v1/appStoreVersions`
3. `PATCH /v1/appStoreVersions/{id}`
4. `PATCH /v1/appStoreVersions/{id}/relationships/build`
5. `PATCH /v1/builds/{id}`
6. `GET /v1/appStoreVersions/{id}/appStoreVersionLocalizations`
7. `POST /v1/appStoreVersionLocalizations`
8. `PATCH /v1/appStoreVersionLocalizations/{id}`
9. `POST /v1/reviewSubmissions`
10. `POST /v1/reviewSubmissionItems`
11. `PATCH /v1/reviewSubmissions/{id}` with `submitted=true`

## Troubleshooting

1. `401 NOT_AUTHORIZED`: verify `issuer_id`, `key_id`, and matching `.p8` file.
2. Build/encryption errors: patch `usesNonExemptEncryption=false` first, then retry review item creation.
3. Keep iOS/macOS version strings aligned when possible.
