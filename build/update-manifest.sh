#!/usr/bin/env bash
#
# Update versions/builds.tsv with the assets of one Erlang/OTP and AWS-LC
# combination. Rows of the same combination are replaced, and all rows are
# sorted by Erlang/OTP version, AWS-LC version, and target.
#
set -euo pipefail

: "${OTP_VERSION:?OTP_VERSION is required (example: 29.0.6)}"
: "${AWS_LC_VERSION:?AWS_LC_VERSION is required (example: v5.8.0)}"

SOURCE_REPOSITORY="${SOURCE_REPOSITORY:-shiguredo/otp}"
SOURCE_REPOSITORY_URL="${SOURCE_REPOSITORY_URL:-https://github.com/${SOURCE_REPOSITORY}}"
SOURCE_TAG="${SOURCE_TAG:-aws-lc-OTP-${OTP_VERSION}}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-artifacts}"
MANIFEST_FILE="${MANIFEST_FILE:-versions/builds.tsv}"

die() {
    printf 'update-manifest: %s\n' "$1" >&2
    exit 1
}

[[ -f "${MANIFEST_FILE}" ]] || die "manifest not found: ${MANIFEST_FILE}"
[[ -f "${ARTIFACTS_DIR}/SHA256SUMS" ]] || die "checksums not found: ${ARTIFACTS_DIR}/SHA256SUMS"

if ! ls_remote_output="$(git ls-remote "${SOURCE_REPOSITORY_URL}" "refs/tags/${SOURCE_TAG}" 2>&1)"; then
    die "failed to query ${SOURCE_REPOSITORY_URL}: ${ls_remote_output}"
fi
source_sha="$(printf '%s\n' "${ls_remote_output}" | cut -f1)"
[[ -n "${source_sha}" ]] || die "tag not found: ${SOURCE_REPOSITORY} ${SOURCE_TAG}"
source_ref="${SOURCE_REPOSITORY}@${source_sha}"

header="$(grep -E '^#' "${MANIFEST_FILE}" || true)"
tmp="$(mktemp)"
{
    printf '%s\n' "${header}"
    {
        awk -F'\t' -v otp="${OTP_VERSION}" -v aws_lc="${AWS_LC_VERSION}" '
            /^[[:space:]]*(#|$)/ { next }
            NF >= 6 && $1 == otp && $2 == aws_lc { next }
            { print }
        ' "${MANIFEST_FILE}"
        while read -r digest file; do
            target="${file#otp-}"
            target="${target%.tar.gz}"
            printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
                "${OTP_VERSION}" "${AWS_LC_VERSION}" "${target}" "${file}" "${digest}" "${source_ref}"
        done < "${ARTIFACTS_DIR}/SHA256SUMS"
    } |
        sort -t$'\t' -k1,1V -k2,2V -k3,3
} > "${tmp}"
mv "${tmp}" "${MANIFEST_FILE}"

printf 'update-manifest: updated %s for Erlang/OTP %s with AWS-LC %s (%s)\n' \
    "${MANIFEST_FILE}" "${OTP_VERSION}" "${AWS_LC_VERSION}" "${source_ref}"
