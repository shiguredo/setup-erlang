#!/usr/bin/env bash
#
# Build Erlang/OTP with AWS-LC on Ubuntu runners.
#
# The AWS-LC build steps and the Erlang/OTP configure options are the same as
# shiguredo/docker-erlang-otp so that the resulting binaries have the same
# applications and features as the container images.
#
set -euo pipefail

: "${OTP_VERSION:?OTP_VERSION is required (example: 29.0.6)}"
: "${AWS_LC_VERSION:?AWS_LC_VERSION is required (example: v5.8.0)}"
: "${TARGET:?TARGET is required (example: x86_64-unknown-linux-gnu)}"

SOURCE_REPOSITORY="${SOURCE_REPOSITORY:-shiguredo/otp}"
SOURCE_TAG="${SOURCE_TAG:-aws-lc-OTP-${OTP_VERSION}}"
WORK_DIR="${WORK_DIR:-$(pwd)/work}"
OUTPUT_DIR="${OUTPUT_DIR:-$(pwd)/out}"

AWS_LC_SOURCE_DIR="${WORK_DIR}/aws-lc"
AWS_LC_INSTALL_DIR="${WORK_DIR}/aws-lc-install"
OTP_SOURCE_DIR="${WORK_DIR}/otp"
OTP_INSTALL_DIR="${WORK_DIR}/erlang"
ASSET_NAME="otp-${TARGET}.tar.gz"

die() {
    printf 'build-linux: %s\n' "$1" >&2
    exit 1
}

require_commands() {
    local missing=()
    local command
    for command in cmake ninja go git curl tar make gcc nproc readelf sha256sum; do
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
        printf 'build-linux: reusing the AWS-LC installation at %s\n' "${AWS_LC_INSTALL_DIR}"
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
    rm -rf "${OTP_SOURCE_DIR}" "${OTP_INSTALL_DIR}"
    git clone --depth 1 --branch "${SOURCE_TAG}" \
        "https://github.com/${SOURCE_REPOSITORY}" "${OTP_SOURCE_DIR}"
    (
        cd "${OTP_SOURCE_DIR}"
        ./configure \
            --prefix="${OTP_INSTALL_DIR}" \
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
        local jobs
        jobs=$(( $(nproc) - 1 ))
        if (( jobs < 1 )); then
            jobs=1
        fi
        make -j"${jobs}"
        make install
    )
    [[ -x "${OTP_INSTALL_DIR}/bin/erl" ]] ||
        die "the Erlang/OTP installation is incomplete: ${OTP_INSTALL_DIR}/bin/erl is missing"
}

verify_release() {
    local release_dir="$1"
    local erl_bin="${release_dir}/bin/erl"
    [[ -x "${erl_bin}" ]] || die "erl is not found in the release: ${erl_bin}"

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

    local crypto_nif
    crypto_nif="$(find "${release_dir}/lib" -path '*/crypto-*/priv/lib/crypto.so' -print -quit)"
    [[ -n "${crypto_nif}" ]] || die 'crypto NIF is not found in the release'
    if readelf -d "${crypto_nif}" | grep -Eq 'NEEDED.*lib(crypto|ssl)\.so'; then
        die "crypto NIF links against libcrypto or libssl dynamically: ${crypto_nif}"
    fi
    if readelf -d "${crypto_nif}" | grep -Eq 'RPATH|RUNPATH'; then
        die "crypto NIF has an rpath: ${crypto_nif}"
    fi
    printf 'build-linux: verified crypto backend %s\n' "${output}"
}

package() {
    mkdir -p "${OUTPUT_DIR}"
    local asset="${OUTPUT_DIR}/${ASSET_NAME}"
    tar czf "${asset}" -C "${OTP_INSTALL_DIR}" .

    local test_dir="${WORK_DIR}/relocation-test"
    rm -rf "${test_dir}"
    mkdir -p "${test_dir}"
    tar xzf "${asset}" -C "${test_dir}"
    verify_release "${test_dir}"
    rm -rf "${test_dir}"

    local digest
    digest="$(sha256sum "${asset}" | cut -d' ' -f1)"
    printf 'build-linux: wrote %s\n' "${asset}"
    printf 'build-linux: sha256 %s\n' "${digest}"
}

main() {
    require_commands
    mkdir -p "${WORK_DIR}" "${OUTPUT_DIR}"
    printf 'build-linux: Erlang/OTP %s with AWS-LC %s for %s\n' \
        "${OTP_VERSION}" "${AWS_LC_VERSION}" "${TARGET}"
    build_aws_lc
    build_otp
    package
}

main "$@"
