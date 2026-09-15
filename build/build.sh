#!/usr/bin/env bash
#
# Build Erlang/OTP with AWS-LC on Linux and macOS runners.
#
# The AWS-LC build steps and the Erlang/OTP configure options are the same as
# shiguredo/docker-erlang-otp so that the resulting binaries have the same
# applications and features as the container images.
#
# Erlang/OTP is packaged as a release (make release) instead of an installation
# (make install). The installation layout puts erts under lib/erlang, where the
# generated erl script cannot find the root directory after the tree is moved,
# so the release layout is required for a relocatable archive.
#
set -euo pipefail

: "${OTP_VERSION:?OTP_VERSION is required (example: 29.0.6)}"
: "${AWS_LC_VERSION:?AWS_LC_VERSION is required (example: v5.8.0)}"
: "${TARGET:?TARGET is required (example: x86_64-unknown-linux-gnu)}"

SOURCE_REPOSITORY="${SOURCE_REPOSITORY:-shiguredo/otp}"
SOURCE_TAG="${SOURCE_TAG:-aws-lc-OTP-${OTP_VERSION}}"
WORK_DIR="${WORK_DIR:-$(pwd)/work}"
OUTPUT_DIR="${OUTPUT_DIR:-$(pwd)/out}"

PLATFORM="$(uname -s)"

die() {
    printf 'build-erlang: %s\n' "$1" >&2
    exit 1
}

job_count() {
    case "${PLATFORM}" in
        Linux)
            local jobs
            jobs=$(( $(nproc) - 1 ))
            if (( jobs < 1 )); then
                jobs=1
            fi
            printf '%s\n' "${jobs}"
            ;;
        Darwin)
            local cpus
            cpus="$(sysctl -n hw.ncpu)"
            if (( cpus > 2 )); then
                printf '%s\n' "$(( cpus - 1 ))"
            else
                printf '%s\n' "${cpus}"
            fi
            ;;
        *)
            die "unsupported platform: ${PLATFORM}"
            ;;
    esac
}

sha256_of() {
    local file="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "${file}" | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "${file}" | cut -d' ' -f1
    else
        die 'sha256sum or shasum is required'
    fi
}

require_commands() {
    local commands=(cmake ninja go git tar make cc)
    case "${PLATFORM}" in
        Linux)
            commands+=(nproc readelf)
            ;;
        Darwin)
            commands+=(sysctl otool)
            ;;
        *)
            die "unsupported platform: ${PLATFORM}"
            ;;
    esac
    local missing=()
    local command
    for command in "${commands[@]}"; do
        if ! command -v "${command}" >/dev/null 2>&1; then
            missing+=("${command}")
        fi
    done
    if (( ${#missing[@]} > 0 )); then
        die "missing commands: ${missing[*]}"
    fi
}

build_aws_lc() {
    if [[ -f "${AWS_LC_INSTALL_DIR}/lib/libcrypto.a" ]]; then
        printf 'build-erlang: reusing the AWS-LC installation at %s\n' "${AWS_LC_INSTALL_DIR}"
        return
    fi
    rm -rf "${AWS_LC_SOURCE_DIR}" "${AWS_LC_INSTALL_DIR}"
    git clone --depth 1 --branch "${AWS_LC_VERSION}" \
        https://github.com/aws/aws-lc "${AWS_LC_SOURCE_DIR}"
    cmake -S "${AWS_LC_SOURCE_DIR}" -B "${AWS_LC_SOURCE_DIR}/build" -GNinja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="${AWS_LC_INSTALL_DIR}"
    ninja -C "${AWS_LC_SOURCE_DIR}/build"
    ninja -C "${AWS_LC_SOURCE_DIR}/build" install
    [[ -f "${AWS_LC_INSTALL_DIR}/lib/libcrypto.a" ]] ||
        die "the AWS-LC installation is incomplete: ${AWS_LC_INSTALL_DIR}/lib/libcrypto.a is missing"
}

build_otp() {
    rm -rf "${OTP_SOURCE_DIR}" "${RELEASE_DIR}"
    git clone --depth 1 --branch "${SOURCE_TAG}" \
        "https://github.com/${SOURCE_REPOSITORY}" "${OTP_SOURCE_DIR}"
    (
        cd "${OTP_SOURCE_DIR}"
        export ERL_TOP="${OTP_SOURCE_DIR}"
        export ERLC_USE_SERVER=true
        MAKEFLAGS="-j$(job_count)"
        export MAKEFLAGS
        export RELEASE_ROOT="${RELEASE_DIR}"
        ./configure \
            --enable-kernel-poll \
            --enable-dirty-schedulers \
            --enable-jit \
            --disable-sharing-preserving \
            --disable-sctp \
            --disable-dynamic-ssl-lib \
            --with-ssl="${AWS_LC_INSTALL_DIR}" \
            --with-ssl-rpath=no \
            --without-javac \
            --without-odbc \
            --without-wx \
            --without-debugger \
            --without-observer \
            --without-crashdump_viewer \
            --without-et \
            --without-tftp \
            --without-ftp \
            --without-megaco \
            --without-eldap \
            --without-diameter \
            --without-jinterface \
            --without-mnesia \
            --without-snmp \
            --without-erl_docgen \
            --without-ssh
        make release
        cd "${RELEASE_DIR}"
        ./Install -sasl "${PWD}"
        rm -f Install
    )
    [[ -x "${RELEASE_DIR}/bin/erl" ]] ||
        die "the Erlang/OTP release is incomplete: ${RELEASE_DIR}/bin/erl is missing"
}

crypto_nif_in() {
    find "$1/lib" -path '*/crypto-*/priv/lib/crypto.so' -print -quit
}

verify_release() {
    local release_dir="$1"
    local expected_root
    expected_root="$(cd "${release_dir}" && pwd -P)"
    local erl_bin="${expected_root}/bin/erl"
    [[ -x "${erl_bin}" ]] || die "erl is not found in the release: ${erl_bin}"

    local output
    if ! output="$(
        "${erl_bin}" -noshell -eval '{ok, _} = application:ensure_all_started(crypto), [{_, _, VersionString} | _] = crypto:info_lib(), io:format("~s~n", [VersionString]), io:format("~s~n", [code:root_dir()]), halt().' 2>&1
    )"; then
        die "Erlang/OTP failed to start: ${output}"
    fi

    local version_string
    local root_dir
    version_string="$(printf '%s\n' "${output}" | sed -n 1p)"
    root_dir="$(printf '%s\n' "${output}" | sed -n 2p)"
    case "${version_string}" in
        *AWS-LC*) ;;
        *) die "crypto is not linked against AWS-LC: ${version_string}" ;;
    esac
    if [[ "${root_dir}" != "${expected_root}" ]]; then
        die "Erlang/OTP is not relocatable: code:root_dir()=${root_dir}, expected=${expected_root}"
    fi

    local crypto_nif
    crypto_nif="$(crypto_nif_in "${release_dir}")"
    [[ -n "${crypto_nif}" ]] || die 'crypto NIF is not found in the release'
    case "${PLATFORM}" in
        Linux)
            if readelf -d "${crypto_nif}" | grep -Eq 'NEEDED.*lib(crypto|ssl)\.so'; then
                die "crypto NIF links against libcrypto or libssl dynamically: ${crypto_nif}"
            fi
            if readelf -d "${crypto_nif}" | grep -Eq 'RPATH|RUNPATH'; then
                die "crypto NIF has an rpath: ${crypto_nif}"
            fi
            ;;
        Darwin)
            if otool -L "${crypto_nif}" | grep -Eq 'lib(crypto|ssl)\.'; then
                die "crypto NIF links against libcrypto or libssl dynamically: ${crypto_nif}"
            fi
            if otool -l "${crypto_nif}" | grep -q 'LC_RPATH'; then
                die "crypto NIF has an rpath: ${crypto_nif}"
            fi
            ;;
    esac
    printf 'build-erlang: verified crypto backend %s at %s\n' "${version_string}" "${root_dir}"
}

package_release() {
    mkdir -p "${OUTPUT_DIR}"
    local asset="${OUTPUT_DIR}/${ASSET_NAME}"
    tar czf "${asset}" -C "${RELEASE_DIR}" .

    local test_dir="${WORK_DIR}/relocation-test"
    rm -rf "${test_dir}"
    mkdir -p "${test_dir}"
    tar xzf "${asset}" -C "${test_dir}"
    verify_release "${test_dir}"
    rm -rf "${test_dir}"

    local digest
    digest="$(sha256_of "${asset}")"
    printf 'build-erlang: wrote %s\n' "${asset}"
    printf 'build-erlang: sha256 %s\n' "${digest}"
}

main() {
    if [[ "${PLATFORM}" == 'Darwin' ]]; then
        [[ "$(uname -m)" == 'arm64' ]] || die "macOS builds require an arm64 host, got $(uname -m)"
        export COPYFILE_DISABLE=1
    fi
    require_commands
    mkdir -p "${WORK_DIR}" "${OUTPUT_DIR}"
    WORK_DIR="$(cd "${WORK_DIR}" && pwd -P)"
    OUTPUT_DIR="$(cd "${OUTPUT_DIR}" && pwd -P)"

    AWS_LC_SOURCE_DIR="${WORK_DIR}/aws-lc"
    AWS_LC_INSTALL_DIR="${WORK_DIR}/aws-lc-install"
    OTP_SOURCE_DIR="${WORK_DIR}/otp"
    RELEASE_DIR="${WORK_DIR}/erlang"
    ASSET_NAME="otp-${TARGET}.tar.gz"

    printf 'build-erlang: Erlang/OTP %s with AWS-LC %s for %s on %s\n' \
        "${OTP_VERSION}" "${AWS_LC_VERSION}" "${TARGET}" "${PLATFORM}"
    build_aws_lc
    build_otp
    package_release
}

main "$@"
