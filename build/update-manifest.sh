#!/usr/bin/env bash
#
# Update versions/builds.tsv with the assets of one Erlang/OTP and AWS-LC
# combination. The artifacts directory must contain SHA256SUMS for the
# Erlang/OTP tarball (otp-<target>.tar.gz) and the base PLT (otp-<target>.iplt)
# of every target. Rows of the same combination are replaced, and all rows are
# sorted by Erlang/OTP version, AWS-LC version, and target.
#
set -euo pipefail

: "${OTP_VERSION:?OTP_VERSION is required (example: 29.1)}"
: "${AWS_LC_VERSION:?AWS_LC_VERSION is required (example: v5.9.0)}"

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
        # tarball と PLT の 2 行を target ごとに 1 行へまとめる
        awk -v otp="${OTP_VERSION}" -v aws_lc="${AWS_LC_VERSION}" -v source_ref="${source_ref}" '
            {
                digest = $1
                file = $2
                target = file
                sub(/^otp-/, "", target)
                if (file ~ /\.tar\.gz$/) {
                    sub(/\.tar\.gz$/, "", target)
                    tarball[target] = file
                    tarball_sha[target] = digest
                } else if (file ~ /\.iplt$/) {
                    sub(/\.iplt$/, "", target)
                    plt[target] = file
                    plt_sha[target] = digest
                } else {
                    printf "update-manifest: unexpected artifact: %s\n", file > "/dev/stderr"
                    exit 1
                }
                targets[target] = 1
            }
            END {
                for (target in targets) {
                    if (!(target in tarball) || !(target in plt)) {
                        printf "update-manifest: missing asset for %s\n", target > "/dev/stderr"
                        exit 1
                    }
                    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", \
                        otp, aws_lc, target, tarball[target], tarball_sha[target], source_ref, plt[target], plt_sha[target]
                }
            }' "${ARTIFACTS_DIR}/SHA256SUMS"
    } |
        sort -t$'\t' -k1,1V -k2,2V -k3,3
} > "${tmp}"
mv "${tmp}" "${MANIFEST_FILE}"

printf 'update-manifest: updated %s for Erlang/OTP %s with AWS-LC %s (%s)\n' \
    "${MANIFEST_FILE}" "${OTP_VERSION}" "${AWS_LC_VERSION}" "${source_ref}"
