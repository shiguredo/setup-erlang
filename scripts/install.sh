#!/usr/bin/env bash
#
# setup-erlang installer.
#
# Resolves a prebuilt Erlang/OTP asset from versions/builds.tsv, downloads it
# from GitHub Releases, verifies the sha256 checksum, extracts it, and puts the
# bin directory on PATH for the following steps.
#
set -euo pipefail

ACTION_REPOSITORY="${SETUP_ERLANG_REPOSITORY:-shiguredo/setup-erlang}"

die() {
    printf 'setup-erlang: %s\n' "$1" >&2
    exit 1
}

usage() {
    cat <<'USAGE'
Usage: install.sh [resolve|install]

  resolve  Resolve the version, download URL, checksum, and install directory
  install  Install Erlang/OTP (default)
USAGE
}

script_dir() {
    cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
}

manifest_path() {
    if [[ -n "${SETUP_ERLANG_MANIFEST:-}" ]]; then
        printf '%s\n' "${SETUP_ERLANG_MANIFEST}"
    elif [[ -n "${GITHUB_ACTION_PATH:-}" ]]; then
        printf '%s\n' "${GITHUB_ACTION_PATH}/versions/builds.tsv"
    else
        printf '%s\n' "$(script_dir)/../versions/builds.tsv"
    fi
}

set_output() {
    local name="$1"
    local value="$2"
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        printf '%s=%s\n' "${name}" "${value}" >> "${GITHUB_OUTPUT}"
    else
        printf '%s=%s\n' "${name}" "${value}"
    fi
}

detect_target() {
    if [[ -n "${INPUT_OTP_TARGET:-}" ]]; then
        printf '%s\n' "${INPUT_OTP_TARGET}"
        return
    fi
    case "${RUNNER_OS:-}:${RUNNER_ARCH:-}" in
        Linux:X64)
            printf '%s\n' 'x86_64-unknown-linux-gnu'
            ;;
        Linux:ARM64)
            printf '%s\n' 'aarch64-unknown-linux-gnu'
            ;;
        macOS:ARM64)
            printf '%s\n' 'aarch64-apple-darwin'
            ;;
        macOS:X64)
            die 'macOS x64 is not supported; only macOS arm64 (aarch64-apple-darwin) is available'
            ;;
        *)
            die "unsupported runner: RUNNER_OS=${RUNNER_OS:-<unset>} RUNNER_ARCH=${RUNNER_ARCH:-<unset>}"
            ;;
    esac
}

manifest_rows() {
    local file="$1"
    grep -v -E '^[[:space:]]*(#|$)' "${file}" || true
}

available_otp_versions() {
    local file="$1"
    manifest_rows "${file}" | awk -F'\t' 'NF >= 6 { print $1 }' | sort -u | tr '\n' ' '
}

available_aws_lc_versions() {
    local file="$1"
    local otp_version="$2"
    local target="${3:-}"
    manifest_rows "${file}" |
        awk -F'\t' -v otp="${otp_version}" -v target="${target}" \
            'NF >= 6 && $1 == otp && (target == "" || $3 == target) { print $2 }' |
        sort -u | tr '\n' ' '
}

available_targets() {
    local file="$1"
    local otp_version="$2"
    local aws_lc_version="$3"
    manifest_rows "${file}" |
        awk -F'\t' -v otp="${otp_version}" -v aws_lc="${aws_lc_version}" \
            'NF >= 6 && $1 == otp && $2 == aws_lc { print $3 }' |
        sort -u | tr '\n' ' '
}

select_otp_version() {
    local file="$1"
    local requested="$2"
    manifest_rows "${file}" |
        awk -F'\t' -v req="${requested}" '
            NF >= 6 && (req == "latest" || $1 == req || index($1, req ".") == 1) {
                found = $1
            }
            END {
                print found
            }'
}

select_aws_lc_version() {
    local file="$1"
    local otp_version="$2"
    local target="$3"
    local requested="$4"
    manifest_rows "${file}" |
        awk -F'\t' -v otp="${otp_version}" -v target="${target}" -v req="${requested}" '
            NF >= 6 && $1 == otp && $3 == target &&
                (req == "" || $2 == req || $2 == "v" req || substr($2, 2) == req) {
                found = $2
            }
            END {
                print found
            }'
}

select_row() {
    local file="$1"
    local otp_version="$2"
    local aws_lc_version="$3"
    local target="$4"
    local rows
    rows="$(
        manifest_rows "${file}" |
            awk -F'\t' -v otp="${otp_version}" -v aws_lc="${aws_lc_version}" -v target="${target}" \
                'NF >= 6 && $1 == otp && $2 == aws_lc && $3 == target'
    )"
    [[ "$(printf '%s\n' "${rows}" | grep -c .)" == "1" ]] || return 1
    printf '%s\n' "${rows}"
}

install_root_for() {
    local otp_version="$1"
    local aws_lc_version="$2"
    local base="${RUNNER_TOOL_CACHE:-${HOME}/.setup-erlang}"
    printf '%s\n' "${base}/setup-erlang/${otp_version}-aws-lc-${aws_lc_version}"
}

resolve_versions() {
    local manifest
    manifest="$(manifest_path)"
    [[ -f "${manifest}" ]] || die "manifest not found: ${manifest}"
    if [[ -z "$(manifest_rows "${manifest}")" ]]; then
        die "no builds are registered in ${manifest}; run the Build Erlang/OTP workflow first"
    fi

    [[ -n "${INPUT_OTP_VERSION:-}" ]] || die 'otp-version is required'

    TARGET="$(detect_target)"

    OTP_VERSION_RESOLVED="$(select_otp_version "${manifest}" "${INPUT_OTP_VERSION}")"
    if [[ -z "${OTP_VERSION_RESOLVED}" ]]; then
        die "no Erlang/OTP build matches otp-version '${INPUT_OTP_VERSION}' (available: $(available_otp_versions "${manifest}"))"
    fi

    AWS_LC_VERSION_RESOLVED="$(select_aws_lc_version "${manifest}" "${OTP_VERSION_RESOLVED}" "${TARGET}" "${INPUT_AWS_LC_VERSION:-}")"
    if [[ -z "${AWS_LC_VERSION_RESOLVED}" ]]; then
        local available_for_target
        available_for_target="$(available_aws_lc_versions "${manifest}" "${OTP_VERSION_RESOLVED}" "${TARGET}")"
        die "no build for Erlang/OTP ${OTP_VERSION_RESOLVED} with aws-lc-version ${INPUT_AWS_LC_VERSION:-<latest>} on ${TARGET} (available for this target: ${available_for_target:-none})"
    fi

    local row
    row="$(select_row "${manifest}" "${OTP_VERSION_RESOLVED}" "${AWS_LC_VERSION_RESOLVED}" "${TARGET}")" ||
        die "no build for Erlang/OTP ${OTP_VERSION_RESOLVED} + AWS-LC ${AWS_LC_VERSION_RESOLVED} on ${TARGET} (available: $(available_targets "${manifest}" "${OTP_VERSION_RESOLVED}" "${AWS_LC_VERSION_RESOLVED}"))"

    ASSET="$(printf '%s' "${row}" | cut -f4)"
    SHA256="$(printf '%s' "${row}" | cut -f5)"
    SOURCE_REF="$(printf '%s' "${row}" | cut -f6)"
    RELEASE_TAG="otp-${OTP_VERSION_RESOLVED}-aws-lc-${AWS_LC_VERSION_RESOLVED}"
    DOWNLOAD_URL="https://github.com/${ACTION_REPOSITORY}/releases/download/${RELEASE_TAG}/${ASSET}"
    INSTALL_ROOT="$(install_root_for "${OTP_VERSION_RESOLVED}" "${AWS_LC_VERSION_RESOLVED}")"
}

emit_outputs() {
    set_output otp_version "${OTP_VERSION_RESOLVED}"
    set_output aws_lc_version "${AWS_LC_VERSION_RESOLVED}"
    set_output install_root "${INSTALL_ROOT}"
}

download_file() {
    local url="$1"
    local destination="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 --retry-delay 5 -o "${destination}" "${url}" ||
            die "failed to download ${url}"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "${destination}" "${url}" ||
            die "failed to download ${url}"
    else
        die "curl or wget is required to download ${url}"
    fi
}

verify_sha256() {
    local file="$1"
    local expected="$2"
    local actual
    if command -v sha256sum >/dev/null 2>&1; then
        actual="$(sha256sum "${file}" | cut -d' ' -f1)"
    elif command -v shasum >/dev/null 2>&1; then
        actual="$(shasum -a 256 "${file}" | cut -d' ' -f1)"
    else
        die 'sha256sum or shasum is required to verify the downloaded archive'
    fi
    if [[ "${actual}" != "${expected}" ]]; then
        die "sha256 mismatch for ${ASSET}: expected ${expected}, actual ${actual}"
    fi
}

add_to_path() {
    local directory="$1"
    if [[ -n "${GITHUB_PATH:-}" ]]; then
        grep -qxF "${directory}" "${GITHUB_PATH}" 2>/dev/null || printf '%s\n' "${directory}" >> "${GITHUB_PATH}"
    fi
    export PATH="${directory}:${PATH}"
}

verify_installation() {
    local erl_bin="${INSTALL_ROOT}/bin/erl"
    [[ -x "${erl_bin}" ]] || die "erl is not installed at ${erl_bin}"
    local output
    if ! output="$(
        "${erl_bin}" -noshell -eval 'ok = application:ensure_all_started(crypto), [{_, _, VersionString} | _] = crypto:info_lib(), io:format("~s~n", [VersionString]), halt().' 2>&1
    )"; then
        die "Erlang/OTP failed to start: ${output}"
    fi
    case "${output}" in
        *AWS-LC*) ;;
        *) die "crypto is not linked against AWS-LC: ${output}" ;;
    esac
    printf 'setup-erlang: crypto backend is %s\n' "${output}"
}

install_archive() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    local archive="${tmp_dir}/${ASSET}"
    download_file "${DOWNLOAD_URL}" "${archive}"
    verify_sha256 "${archive}" "${SHA256}"
    mkdir -p "$(dirname "${INSTALL_ROOT}")"
    rm -rf "${INSTALL_ROOT}.tmp"
    mkdir -p "${INSTALL_ROOT}.tmp"
    tar -xzf "${archive}" -C "${INSTALL_ROOT}.tmp"
    rm -rf "${INSTALL_ROOT}"
    mv "${INSTALL_ROOT}.tmp" "${INSTALL_ROOT}"
    printf '%s\n' "${OTP_VERSION_RESOLVED}" > "${INSTALL_ROOT}/.setup-erlang-otp-version"
    printf '%s\n' "${AWS_LC_VERSION_RESOLVED}" > "${INSTALL_ROOT}/.setup-erlang-aws-lc-version"
    : > "${INSTALL_ROOT}/.setup-erlang-complete"
    rm -rf "${tmp_dir}"
}

resolve_command() {
    resolve_versions
    emit_outputs
    printf 'setup-erlang: resolved Erlang/OTP %s with AWS-LC %s for %s (source %s)\n' \
        "${OTP_VERSION_RESOLVED}" "${AWS_LC_VERSION_RESOLVED}" "${TARGET}" "${SOURCE_REF}"
}

install_command() {
    resolve_versions
    if [[ -f "${INSTALL_ROOT}/.setup-erlang-complete" ]]; then
        printf 'setup-erlang: Erlang/OTP %s with AWS-LC %s is already installed at %s\n' \
            "${OTP_VERSION_RESOLVED}" "${AWS_LC_VERSION_RESOLVED}" "${INSTALL_ROOT}"
    else
        install_archive
    fi
    add_to_path "${INSTALL_ROOT}/bin"
    verify_installation
    emit_outputs
    printf 'setup-erlang: installed Erlang/OTP %s with AWS-LC %s at %s\n' \
        "${OTP_VERSION_RESOLVED}" "${AWS_LC_VERSION_RESOLVED}" "${INSTALL_ROOT}"
}

main() {
    local command="${1:-install}"
    case "${command}" in
        resolve)
            resolve_command
            ;;
        install)
            install_command
            ;;
        -h | --help | help)
            usage
            ;;
        *)
            usage >&2
            die "unknown command: ${command}"
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
