#!/usr/bin/env bash
#
# Update versions/builds.tsv with the assets of one Erlang/OTP and AWS-LC
# combination. The artifacts directory must contain SHA256SUMS.
#
# DEBUG=false replaces the release rows. SHA256SUMS must contain the tarball
# (otp-<target>.tar.gz) and the base PLT (otp-<target>.iplt) of every target.
#
# DEBUG=true replaces the debug rows (otp-<target>-debug.tar.gz). The debug
# build does not ship its own PLT. The plt columns are copied from the release
# row of the same Erlang/OTP, AWS-LC, and target, which must already be in the
# manifest. A missing debug column on an existing row means the release build.
#
set -euo pipefail

: "${OTP_VERSION:?OTP_VERSION is required (example: 29.1.2)}"
: "${AWS_LC_VERSION:?AWS_LC_VERSION is required (example: v5.11.0)}"

DEBUG="${DEBUG:-false}"
SOURCE_REPOSITORY="${SOURCE_REPOSITORY:-shiguredo/otp}"
SOURCE_REPOSITORY_URL="${SOURCE_REPOSITORY_URL:-https://github.com/${SOURCE_REPOSITORY}}"
SOURCE_TAG="${SOURCE_TAG:-aws-lc-OTP-${OTP_VERSION}}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-artifacts}"
MANIFEST_FILE="${MANIFEST_FILE:-versions/builds.tsv}"

die() {
    printf 'update-manifest: %s\n' "$1" >&2
    exit 1
}

case "${DEBUG}" in
    true | false) ;;
    *) die "DEBUG must be true or false (got ${DEBUG})" ;;
esac

[[ -f "${MANIFEST_FILE}" ]] || die "manifest not found: ${MANIFEST_FILE}"
[[ -f "${ARTIFACTS_DIR}/SHA256SUMS" ]] || die "checksums not found: ${ARTIFACTS_DIR}/SHA256SUMS"

if ! ls_remote_output="$(git ls-remote "${SOURCE_REPOSITORY_URL}" "refs/tags/${SOURCE_TAG}" 2>&1)"; then
    die "failed to query ${SOURCE_REPOSITORY_URL}: ${ls_remote_output}"
fi
source_sha="$(printf '%s\n' "${ls_remote_output}" | cut -f1)"
[[ -n "${source_sha}" ]] || die "tag not found: ${SOURCE_REPOSITORY} ${SOURCE_TAG}"
source_ref="${SOURCE_REPOSITORY}@${source_sha}"

parsed_assets="$(mktemp)"
awk -v debug="${DEBUG}" '
    BEGIN { failed = 0 }
    function fail(message) {
        printf "update-manifest: %s\n", message > "/dev/stderr"
        failed = 1
        exit 1
    }
    NF < 2 {
        fail("malformed checksum line: " $0)
    }
    {
        digest = $1
        file = $2
        target = file
        sub(/^otp-/, "", target)
        kind = ""
        if (file ~ /-debug\.tar\.gz$/) {
            if (debug != "true") {
                fail(file " does not match DEBUG=" debug)
            }
            sub(/-debug\.tar\.gz$/, "", target)
            kind = "tarball"
        } else if (file ~ /\.tar\.gz$/) {
            if (debug != "false") {
                fail(file " does not match DEBUG=" debug)
            }
            sub(/\.tar\.gz$/, "", target)
            kind = "tarball"
        } else if (file ~ /\.iplt$/) {
            if (debug != "false") {
                fail(file " does not match DEBUG=" debug)
            }
            sub(/\.iplt$/, "", target)
            kind = "plt"
        } else {
            fail("unexpected artifact: " file)
        }
        printf "%s\t%s\t%s\t%s\n", kind, target, file, digest
        count++
    }
    END {
        if (failed) {
            exit 1
        }
        if (count == 0) {
            printf "update-manifest: SHA256SUMS has no assets\n" > "/dev/stderr"
            exit 1
        }
    }' "${ARTIFACTS_DIR}/SHA256SUMS" > "${parsed_assets}"

header='# otp_version	aws_lc_version	target	asset	sha256	source_ref	plt_asset	plt_sha256	debug'
tmp="$(mktemp)"
{
    printf '%s\n' "${header}"
    {
        awk -F'\t' -v otp="${OTP_VERSION}" -v aws_lc="${AWS_LC_VERSION}" -v debug="${DEBUG}" '
            function row_debug() {
                return (NF >= 9 && $9 == "true") ? "true" : "false"
            }
            /^[[:space:]]*(#|$)/ { next }
            NF >= 6 && $1 == otp && $2 == aws_lc && row_debug() == debug { next }
            { print }
        ' "${MANIFEST_FILE}"
        awk -F'\t' -v otp="${OTP_VERSION}" -v aws_lc="${AWS_LC_VERSION}" -v source_ref="${source_ref}" \
            -v debug="${DEBUG}" -v manifest="${MANIFEST_FILE}" -v parsed="${parsed_assets}" '
            function row_debug() {
                return (NF >= 9 && $9 == "true") ? "true" : "false"
            }
            FILENAME == parsed {
                kind = $1
                target = $2
                file = $3
                digest = $4
                targets[target] = 1
                if (kind == "tarball") {
                    tarball[target] = file
                    tarball_sha[target] = digest
                } else if (kind == "plt") {
                    plt[target] = file
                    plt_sha[target] = digest
                }
                next
            }
            FILENAME == manifest && ($0 ~ /^[[:space:]]*(#|$)/ || NF < 8) { next }
            FILENAME == manifest && row_debug() == "false" {
                release_plt[$1 SUBSEP $2 SUBSEP $3] = $7
                release_plt_sha[$1 SUBSEP $2 SUBSEP $3] = $8
            }
            END {
                for (target in targets) {
                    if (!(target in tarball)) {
                        printf "update-manifest: missing tarball for %s\n", target > "/dev/stderr"
                        exit 1
                    }
                    if (debug == "true") {
                        key = otp SUBSEP aws_lc SUBSEP target
                        if (!(key in release_plt) || release_plt[key] == "" || release_plt_sha[key] == "") {
                            printf "update-manifest: no release PLT for %s %s %s; publish the release build first\n", otp, aws_lc, target > "/dev/stderr"
                            exit 1
                        }
                        plt_file = release_plt[key]
                        plt_digest = release_plt_sha[key]
                    } else {
                        if (!(target in plt) || plt[target] == "") {
                            printf "update-manifest: missing PLT for %s\n", target > "/dev/stderr"
                            exit 1
                        }
                        plt_file = plt[target]
                        plt_digest = plt_sha[target]
                    }
                    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", \
                        otp, aws_lc, target, tarball[target], tarball_sha[target], source_ref, plt_file, plt_digest, debug
                }
            }' "${parsed_assets}" "${MANIFEST_FILE}"
    } |
        sort -t$'\t' -k1,1V -k2,2V -k3,3 -k9,9
} > "${tmp}"
rm -f "${parsed_assets}"
mv "${tmp}" "${MANIFEST_FILE}"

printf 'update-manifest: updated %s for Erlang/OTP %s with AWS-LC %s (%s, debug %s)\n' \
    "${MANIFEST_FILE}" "${OTP_VERSION}" "${AWS_LC_VERSION}" "${source_ref}" "${DEBUG}"
