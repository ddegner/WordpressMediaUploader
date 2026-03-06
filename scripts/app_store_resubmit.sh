#!/usr/bin/env bash
set -euo pipefail
umask 077

APP_ID="${APP_ID:-6759262491}"
VERSION_STRING="${VERSION_STRING:-}"
PLATFORM="${PLATFORM:-MAC_OS}"
LOCALE="${LOCALE:-en-US}"
REVIEW_SUBMISSION_POLL_TIMEOUT_SECONDS="${REVIEW_SUBMISSION_POLL_TIMEOUT_SECONDS:-180}"
BUILD_NUMBER="${BUILD_NUMBER:-}"
AUTO_ATTACH_LATEST_BUILD="${AUTO_ATTACH_LATEST_BUILD:-1}"
USES_NON_EXEMPT_ENCRYPTION="${USES_NON_EXEMPT_ENCRYPTION:-false}"
REVIEW_NOTES_FILE="${REVIEW_NOTES_FILE:-apple-reviewer-instructions.md}"

NEW_SUBTITLE="${NEW_SUBTITLE:-Bulk WordPress Media Uploads}"
NEW_KEYWORDS="${NEW_KEYWORDS:-wordpress,wp-cli,media uploader,ssh,rsync,bulk upload,images,photos,blogging}"

ASC_KEY_ID="${ASC_KEY_ID:-}"
ASC_ISSUER_ID="${ASC_ISSUER_ID:-}"
API_PRIVATE_KEYS_DIR="${API_PRIVATE_KEYS_DIR:-$HOME/.appstoreconnect/private_keys}"

if [[ -z "${VERSION_STRING}" ]]; then
    echo "ERROR: VERSION_STRING is required."
    echo "Set it to the App Store version you want to submit (for example VERSION_STRING=1.0)."
    exit 1
fi

if [[ -z "${ASC_KEY_ID}" ]]; then
    echo "ERROR: ASC_KEY_ID is required."
    echo "Set it from App Store Connect -> Users and Access -> Integrations -> Key ID."
    exit 1
fi

if [[ -z "${ASC_ISSUER_ID}" ]]; then
    echo "ERROR: ASC_ISSUER_ID is required."
    echo "Set it from App Store Connect -> Users and Access -> Integrations -> Issuer ID."
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required."
    exit 1
fi

case "${USES_NON_EXEMPT_ENCRYPTION}" in
    true|false)
        ;;
    *)
        echo "ERROR: USES_NON_EXEMPT_ENCRYPTION must be true or false."
        exit 1
        ;;
esac

key_path_auth="${API_PRIVATE_KEYS_DIR}/AuthKey_${ASC_KEY_ID}.p8"
key_path_api="${API_PRIVATE_KEYS_DIR}/ApiKey_${ASC_KEY_ID}.p8"

if [[ -f "${key_path_auth}" ]]; then
    ASC_KEY_PATH="${key_path_auth}"
elif [[ -f "${key_path_api}" ]]; then
    ASC_KEY_PATH="${key_path_api}"
else
    echo "ERROR: Could not find key file for ${ASC_KEY_ID} in ${API_PRIVATE_KEYS_DIR}."
    exit 1
fi

generate_jwt() {
    python3 - "$ASC_KEY_ID" "$ASC_ISSUER_ID" "$ASC_KEY_PATH" <<'PY'
import base64
import json
import subprocess
import sys
import time

kid, iss, key_path = sys.argv[1], sys.argv[2], sys.argv[3]

def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")

def read_len(data: bytes, idx: int):
    first = data[idx]
    idx += 1
    if first < 0x80:
        return first, idx
    width = first & 0x7F
    length = int.from_bytes(data[idx:idx + width], "big")
    idx += width
    return length, idx

def der_to_raw_p256(sig_der: bytes) -> bytes:
    idx = 0
    if sig_der[idx] != 0x30:
        raise ValueError("invalid DER sequence")
    idx += 1
    _, idx = read_len(sig_der, idx)

    if sig_der[idx] != 0x02:
        raise ValueError("invalid DER integer for r")
    idx += 1
    r_len, idx = read_len(sig_der, idx)
    r = sig_der[idx:idx + r_len]
    idx += r_len

    if sig_der[idx] != 0x02:
        raise ValueError("invalid DER integer for s")
    idx += 1
    s_len, idx = read_len(sig_der, idx)
    s = sig_der[idx:idx + s_len]

    r_int = int.from_bytes(r, "big")
    s_int = int.from_bytes(s, "big")
    return r_int.to_bytes(32, "big") + s_int.to_bytes(32, "big")

header = {"alg": "ES256", "kid": kid, "typ": "JWT"}
payload = {
    "iss": iss,
    "aud": "appstoreconnect-v1",
    "exp": int(time.time()) + 900,
}

unsigned = f"{b64url(json.dumps(header, separators=(',', ':')).encode())}.{b64url(json.dumps(payload, separators=(',', ':')).encode())}"
sig_der = subprocess.check_output(
    ["openssl", "dgst", "-binary", "-sha256", "-sign", key_path],
    input=unsigned.encode("utf-8"),
)
sig_raw = der_to_raw_p256(sig_der)
print(f"{unsigned}.{b64url(sig_raw)}", end="")
PY
}

asc_api() {
    local method="$1"
    local path="$2"
    local payload="${3:-}"
    local token status response_file

    token="$(generate_jwt)"
    response_file="$(mktemp)"

    if [[ -n "${payload}" ]]; then
        status="$(curl -sS -o "${response_file}" -w "%{http_code}" \
            -X "${method}" \
            -H "Authorization: Bearer ${token}" \
            -H "Content-Type: application/json" \
            "https://api.appstoreconnect.apple.com${path}" \
            -d "${payload}")"
    else
        status="$(curl -sS -o "${response_file}" -w "%{http_code}" \
            -X "${method}" \
            -H "Authorization: Bearer ${token}" \
            "https://api.appstoreconnect.apple.com${path}")"
    fi

    if [[ "${status}" -lt 200 || "${status}" -gt 299 ]]; then
        echo "ASC API ${method} ${path} failed with HTTP ${status}" >&2
        cat "${response_file}" >&2
        rm -f "${response_file}"
        return 1
    fi

    cat "${response_file}"
    rm -f "${response_file}"
}

echo "==> Resolving App Store Version (${VERSION_STRING}, ${PLATFORM})"
versions_json="$(asc_api GET "/v1/apps/${APP_ID}/appStoreVersions?filter%5BversionString%5D=${VERSION_STRING}&filter%5Bplatform%5D=${PLATFORM}&include=appStoreVersionLocalizations&limit%5BappStoreVersionLocalizations%5D=50")"
app_store_version_id="$(printf '%s' "${versions_json}" | jq -r '.data[0].id // empty')"
app_store_version_localization_id="$(
    printf '%s' "${versions_json}" |
        jq -r --arg locale "${LOCALE}" '.included[]? | select(.type=="appStoreVersionLocalizations" and .attributes.locale==$locale) | .id' |
        head -n 1
)"

if [[ -z "${app_store_version_id}" ]]; then
    echo "ERROR: Could not find appStoreVersion for app ${APP_ID} version ${VERSION_STRING} (${PLATFORM})."
    exit 1
fi

echo "==> Resolving App Info localization (${LOCALE})"
app_infos_json="$(asc_api GET "/v1/apps/${APP_ID}/appInfos")"
app_info_id="$(printf '%s' "${app_infos_json}" | jq -r '.data[0].id // empty')"
if [[ -z "${app_info_id}" ]]; then
    echo "ERROR: Could not resolve appInfo ID for app ${APP_ID}."
    exit 1
fi

app_info_localizations_json="$(asc_api GET "/v1/appInfos/${app_info_id}/appInfoLocalizations")"
app_info_localization_id="$(
    printf '%s' "${app_info_localizations_json}" |
        jq -r --arg locale "${LOCALE}" '.data[]? | select(.attributes.locale==$locale) | .id' |
        head -n 1
)"

if [[ -z "${app_info_localization_id}" ]]; then
    echo "ERROR: Could not resolve appInfoLocalization for locale ${LOCALE}."
    exit 1
fi

echo "==> Updating subtitle to: ${NEW_SUBTITLE}"
subtitle_payload="$(jq -cn \
    --arg id "${app_info_localization_id}" \
    --arg subtitle "${NEW_SUBTITLE}" \
    '{data:{type:"appInfoLocalizations",id:$id,attributes:{subtitle:$subtitle}}}')"
asc_api PATCH "/v1/appInfoLocalizations/${app_info_localization_id}" "${subtitle_payload}" >/dev/null

if [[ -n "${app_store_version_localization_id}" ]]; then
    echo "==> Updating keywords to remove Apple trademark term usage"
    keywords_payload="$(jq -cn \
        --arg id "${app_store_version_localization_id}" \
        --arg keywords "${NEW_KEYWORDS}" \
        '{data:{type:"appStoreVersionLocalizations",id:$id,attributes:{keywords:$keywords}}}')"
    asc_api PATCH "/v1/appStoreVersionLocalizations/${app_store_version_localization_id}" "${keywords_payload}" >/dev/null
else
    echo "WARN: appStoreVersionLocalization for ${LOCALE} not found; skipping keywords update."
fi

echo "==> Checking current App Store version state"
version_json="$(asc_api GET "/v1/appStoreVersions/${app_store_version_id}")"
app_store_state="$(printf '%s' "${version_json}" | jq -r '.data.attributes.appStoreState // "UNKNOWN"')"
echo "Current state: ${app_store_state}"

case "${app_store_state}" in
    WAITING_FOR_REVIEW|IN_REVIEW|PENDING_DEVELOPER_RELEASE|PENDING_APPLE_RELEASE|READY_FOR_SALE)
        echo "==> Version already submitted or beyond submission state; no new submission created."
        ;;
    *)
        if [[ -n "${REVIEW_NOTES_FILE}" ]]; then
            if [[ -f "${REVIEW_NOTES_FILE}" ]]; then
                echo "==> Updating App Review notes from ${REVIEW_NOTES_FILE}"
                review_detail_json="$(asc_api GET "/v1/appStoreVersions/${app_store_version_id}/appStoreReviewDetail")"
                app_store_review_detail_id="$(printf '%s' "${review_detail_json}" | jq -r '.data.id // empty')"
                if [[ -n "${app_store_review_detail_id}" ]]; then
                    review_notes_payload="$(jq -cn \
                        --arg id "${app_store_review_detail_id}" \
                        --rawfile notes "${REVIEW_NOTES_FILE}" \
                        '{data:{type:"appStoreReviewDetails",id:$id,attributes:{notes:$notes}}}')"
                    asc_api PATCH "/v1/appStoreReviewDetails/${app_store_review_detail_id}" "${review_notes_payload}" >/dev/null
                else
                    echo "WARN: appStoreReviewDetail not found for version ${VERSION_STRING}; skipping review notes update."
                fi
            else
                echo "WARN: REVIEW_NOTES_FILE not found: ${REVIEW_NOTES_FILE}; skipping review notes update."
            fi
        fi

        if [[ "${AUTO_ATTACH_LATEST_BUILD}" == "1" || -n "${BUILD_NUMBER}" ]]; then
            echo "==> Resolving valid build for version ${VERSION_STRING} (${PLATFORM})"
            builds_json="$(asc_api GET "/v1/builds?filter%5Bapp%5D=${APP_ID}&filter%5BpreReleaseVersion.version%5D=${VERSION_STRING}&filter%5BpreReleaseVersion.platform%5D=${PLATFORM}&filter%5BprocessingState%5D=VALID&sort=-uploadedDate&limit=200")"
            if [[ -n "${BUILD_NUMBER}" ]]; then
                selected_build_id="$(
                    printf '%s' "${builds_json}" |
                        jq -r --arg build_number "${BUILD_NUMBER}" '.data[]? | select(.attributes.version==$build_number) | .id' |
                        head -n 1
                )"
                selected_build_number="${BUILD_NUMBER}"
            else
                selected_build_id="$(printf '%s' "${builds_json}" | jq -r '.data[0].id // empty')"
                selected_build_number="$(printf '%s' "${builds_json}" | jq -r '.data[0].attributes.version // empty')"
            fi

            if [[ -z "${selected_build_id}" ]]; then
                if [[ -n "${BUILD_NUMBER}" ]]; then
                    echo "ERROR: Could not find VALID build ${BUILD_NUMBER} for version ${VERSION_STRING} (${PLATFORM})."
                else
                    echo "ERROR: Could not find a VALID build for version ${VERSION_STRING} (${PLATFORM})."
                    echo "Wait for build processing to finish in App Store Connect, then retry."
                fi
                exit 1
            fi

            echo "==> Attaching build ${selected_build_number} to appStoreVersion ${app_store_version_id}"
            attach_build_payload="$(jq -cn \
                --arg build_id "${selected_build_id}" \
                '{data:{type:"builds",id:$build_id}}')"
            asc_api PATCH "/v1/appStoreVersions/${app_store_version_id}/relationships/build" "${attach_build_payload}" >/dev/null

            echo "==> Ensuring encryption declaration on build ${selected_build_number}"
            build_details_json="$(asc_api GET "/v1/builds/${selected_build_id}")"
            current_uses_non_exempt="$(
                printf '%s' "${build_details_json}" |
                    jq -r '.data.attributes.usesNonExemptEncryption // empty'
            )"

            if [[ "${current_uses_non_exempt}" == "${USES_NON_EXEMPT_ENCRYPTION}" ]]; then
                echo "==> Encryption declaration already set to ${USES_NON_EXEMPT_ENCRYPTION}; skipping update."
            else
                encryption_payload="$(jq -cn \
                    --arg id "${selected_build_id}" \
                    --argjson uses_non_exempt "${USES_NON_EXEMPT_ENCRYPTION}" \
                    '{data:{type:"builds",id:$id,attributes:{usesNonExemptEncryption:$uses_non_exempt}}}')"
                asc_api PATCH "/v1/builds/${selected_build_id}" "${encryption_payload}" >/dev/null
            fi
        fi

        echo "==> Reconciling review submissions for resubmission"
        review_submissions_json="$(asc_api GET "/v1/reviewSubmissions?filter%5Bapp%5D=${APP_ID}&limit=50")"

        while IFS=$'\t' read -r review_submission_id review_submission_state; do
            [[ -z "${review_submission_id}" ]] && continue
            case "${review_submission_state}" in
                COMPLETE|CANCELED)
                    continue
                    ;;
            esac

            echo "==> Canceling review submission ${review_submission_id} (state: ${review_submission_state})"
            cancel_payload="$(jq -cn \
                --arg id "${review_submission_id}" \
                '{data:{type:"reviewSubmissions",id:$id,attributes:{canceled:true}}}')"
            asc_api PATCH "/v1/reviewSubmissions/${review_submission_id}" "${cancel_payload}" >/dev/null

            echo "==> Waiting for ${review_submission_id} to settle after cancellation"
            max_polls=$((REVIEW_SUBMISSION_POLL_TIMEOUT_SECONDS / 3))
            if (( max_polls < 1 )); then
                max_polls=1
            fi

            settled_state=""
            for ((poll=1; poll<=max_polls; poll++)); do
                settled_state="$(
                    asc_api GET "/v1/reviewSubmissions/${review_submission_id}" |
                        jq -r '.data.attributes.state // "UNKNOWN"'
                )"
                echo "    poll ${poll}/${max_polls}: ${settled_state}"
                case "${settled_state}" in
                    COMPLETE|CANCELED)
                        break
                        ;;
                esac
                sleep 3
            done

            if [[ "${settled_state}" != "COMPLETE" && "${settled_state}" != "CANCELED" ]]; then
                echo "ERROR: review submission ${review_submission_id} did not settle (final state: ${settled_state})."
                exit 1
            fi
        done < <(
            printf '%s' "${review_submissions_json}" |
                jq -r '.data[]? | [.id, .attributes.state] | @tsv'
        )

        echo "==> Creating reviewSubmission"
        review_submission_payload="$(jq -cn \
            --arg app_id "${APP_ID}" \
            '{data:{type:"reviewSubmissions",relationships:{app:{data:{type:"apps",id:$app_id}}}}}')"
        new_review_submission_json="$(asc_api POST "/v1/reviewSubmissions" "${review_submission_payload}")"
        new_review_submission_id="$(printf '%s' "${new_review_submission_json}" | jq -r '.data.id // empty')"
        if [[ -z "${new_review_submission_id}" ]]; then
            echo "ERROR: Failed to create reviewSubmission."
            exit 1
        fi

        echo "==> Creating reviewSubmissionItem for appStoreVersion ${app_store_version_id}"
        review_item_payload="$(jq -cn \
            --arg review_submission_id "${new_review_submission_id}" \
            --arg app_store_version_id "${app_store_version_id}" \
            '{data:{type:"reviewSubmissionItems",relationships:{reviewSubmission:{data:{type:"reviewSubmissions",id:$review_submission_id}},appStoreVersion:{data:{type:"appStoreVersions",id:$app_store_version_id}}}}}')"
        asc_api POST "/v1/reviewSubmissionItems" "${review_item_payload}" >/dev/null

        echo "==> Submitting reviewSubmission ${new_review_submission_id}"
        submit_payload="$(jq -cn \
            --arg id "${new_review_submission_id}" \
            '{data:{type:"reviewSubmissions",id:$id,attributes:{submitted:true}}}')"
        submitted_review_json="$(asc_api PATCH "/v1/reviewSubmissions/${new_review_submission_id}" "${submit_payload}")"
        submitted_state="$(printf '%s' "${submitted_review_json}" | jq -r '.data.attributes.state // "UNKNOWN"')"
        submitted_date="$(printf '%s' "${submitted_review_json}" | jq -r '.data.attributes.submittedDate // empty')"
        echo "==> Review submission state: ${submitted_state}"
        [[ -n "${submitted_date}" ]] && echo "==> Review submitted at: ${submitted_date}"
        ;;
esac

echo "Done."
