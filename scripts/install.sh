#!/usr/bin/env bash
#
# setup-erlang installer.
#
# GitHub Actions の composite action からも、ローカルの Ubuntu / macOS からも
# 同じスクリプトで Erlang/OTP をインストールできる。
#
# GitHub Actions:
#   RUNNER_TOOL_CACHE 配下へインストールし、GITHUB_PATH / GITHUB_OUTPUT を通して
#   後続ステップへ引き継ぐ。otp-version は完全一致で指定する。
#
# ローカル (GitHub Actions 以外):
#   ${XDG_DATA_HOME:-$HOME/.local/share}/setup-erlang 配下へインストールし、
#   <base>/current をインストールしたバージョンへ向けた symlink にして、
#   PATH の設定方法を案内する。otp-version を省略すると最新をインストールする。
#
#   erl は $0 の位置から ROOTDIR を求めるため、bin/erl などのファイル単位の
#   symlink を PATH に置くと動かない。必ず <base>/current のディレクトリ
#   symlink を PATH に通すこと。
#
# マニフェスト (versions/builds.tsv) は、リポジトリ内で実行した場合はその
# チェックアウトのものを使い、それ以外は GitHub からダウンロードして
# ${XDG_CACHE_HOME:-$HOME/.cache}/setup-erlang/manifest.tsv にキャッシュする。
#
# When INPUT_USE_PLT is true (the default), the dialyzer base PLT (incremental)
# shipped with the release is installed so that rebar3 can use it as the seed
# of its project PLTs. The PLT is stored in the install directory (so that it
# is covered by RUNNER_TOOL_CACHE and actions/cache as well) and copied to
# $HOME/.cache/rebar3, which is where rebar3 looks for the base PLT by default.
#
set -euo pipefail

ACTION_REPOSITORY="${SETUP_ERLANG_REPOSITORY:-shiguredo/setup-erlang}"
RELEASE_BASE_URL="${SETUP_ERLANG_RELEASE_BASE_URL:-https://github.com/${ACTION_REPOSITORY}/releases/download}"
MANIFEST_REF="${SETUP_ERLANG_MANIFEST_REF:-main}"

# GitHub Actions では完全一致のバージョンだけを受け付け、ローカルでは latest を
# 受け付ける (省略時は latest 扱い)
ACTION_MODE=false
if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    ACTION_MODE=true
fi

# プリビルドバイナリは Ubuntu 24.04 (glibc 2.39) でビルドしており、
# 最大で glibc 2.38 のシンボルを参照する
GLIBC_REQUIRED_MAJOR=2
GLIBC_REQUIRED_MINOR=38

COMMAND=install
USE_VERSION=
USE_AWS_LC_VERSION=

die() {
    printf 'setup-erlang: %s\n' "$1" >&2
    exit 1
}

usage() {
    cat <<'USAGE'
Usage: install.sh [command] [options] [otp-version [aws-lc-version]]

Install prebuilt Erlang/OTP with AWS-LC. Outside GitHub Actions the latest
version is installed when no version is specified.

Commands:
  install   Install Erlang/OTP (default)
  resolve   Print the resolved version and paths without downloading
  list      Show the installed and available versions
  use       Switch the current version to an installed one

Options:
  --otp-version VERSION     Erlang/OTP version (default: latest)
  --aws-lc-version VERSION  AWS-LC version (default: latest for the version)
  --target TARGET           Target triple override (example: aarch64-apple-darwin)
  --root DIR                Install root (default: ${XDG_DATA_HOME:-$HOME/.local/share}/setup-erlang)
  --no-plt                  Do not install the dialyzer base PLT
  -h, --help                Show this help

Environment:
  INPUT_OTP_VERSION         Same as --otp-version
  INPUT_AWS_LC_VERSION      Same as --aws-lc-version
  INPUT_OTP_TARGET          Same as --target
  INPUT_USE_PLT             "false" disables the base PLT
  SETUP_ERLANG_ROOT         Same as --root
  SETUP_ERLANG_MANIFEST     Manifest file to use instead of the built-in one
  SETUP_ERLANG_MANIFEST_URL Manifest URL (default: raw.githubusercontent.com)
  SETUP_ERLANG_MANIFEST_REF Manifest ref used for the URL (default: main)

Examples:
  curl -fsSL https://raw.githubusercontent.com/shiguredo/setup-erlang/main/scripts/install.sh | bash
  curl -fsSL .../install.sh | bash -s -- 29.1.1
  curl -fsSL .../install.sh | bash -s -- list
  install.sh use 29.1.1 v5.11.0
USAGE
}

script_path() {
    # curl | bash のように標準入力から実行された場合は空になる
    local src="${BASH_SOURCE[0]:-}"
    if [[ -n "${src}" && -f "${src}" ]]; then
        printf '%s\n' "${src}"
    fi
}

try_download_file() {
    local url="$1"
    local destination="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 --retry-delay 5 -o "${destination}" "${url}"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "${destination}" "${url}"
    else
        return 1
    fi
}

download_file() {
    local url="$1"
    local destination="$2"
    try_download_file "${url}" "${destination}" ||
        die "failed to download ${url}; curl or wget is required"
}

manifest_cache_file() {
    local cache_home="${XDG_CACHE_HOME:-}"
    if [[ -z "${cache_home}" ]]; then
        [[ -n "${HOME:-}" ]] || die 'HOME or XDG_CACHE_HOME is required to cache the manifest'
        cache_home="${HOME}/.cache"
    fi
    printf '%s\n' "${cache_home}/setup-erlang/manifest.tsv"
}

manifest_url() {
    printf '%s\n' "${SETUP_ERLANG_MANIFEST_URL:-https://raw.githubusercontent.com/${ACTION_REPOSITORY}/${MANIFEST_REF}/versions/builds.tsv}"
}

fetch_manifest() {
    local cache_file
    local url
    local tmp
    cache_file="$(manifest_cache_file)"
    url="$(manifest_url)"
    mkdir -p "$(dirname "${cache_file}")"
    tmp="${cache_file}.tmp.$$"
    printf 'setup-erlang: downloading the manifest from %s\n' "${url}" >&2
    if try_download_file "${url}" "${tmp}" && [[ -s "${tmp}" ]]; then
        mv "${tmp}" "${cache_file}"
    else
        rm -f "${tmp}"
        if [[ ! -s "${cache_file}" ]]; then
            die "failed to download the manifest from ${url}"
        fi
        printf 'setup-erlang: using the cached manifest at %s\n' "${cache_file}" >&2
    fi
    printf '%s\n' "${cache_file}"
}

manifest_path() {
    if [[ -n "${SETUP_ERLANG_MANIFEST:-}" ]]; then
        [[ -f "${SETUP_ERLANG_MANIFEST}" ]] || die "manifest not found: ${SETUP_ERLANG_MANIFEST}"
        printf '%s\n' "${SETUP_ERLANG_MANIFEST}"
        return
    fi
    # composite action は自分自身のチェックアウトのマニフェストを使う
    if [[ -n "${GITHUB_ACTION_PATH:-}" ]]; then
        [[ -f "${GITHUB_ACTION_PATH}/versions/builds.tsv" ]] ||
            die "manifest not found: ${GITHUB_ACTION_PATH}/versions/builds.tsv"
        printf '%s\n' "${GITHUB_ACTION_PATH}/versions/builds.tsv"
        return
    fi
    # リポジトリ内で実行した場合はチェックアウトのマニフェストを使う
    local src
    src="$(script_path)"
    if [[ -n "${src}" ]]; then
        local local_manifest
        local_manifest="$(cd "$(dirname "${src}")/.." && pwd)/versions/builds.tsv"
        if [[ -f "${local_manifest}" ]]; then
            printf '%s\n' "${local_manifest}"
            return
        fi
    fi
    fetch_manifest
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

# $1 が "stdout" のときだけ、GITHUB_OUTPUT が無い場合に標準出力へ出す
# (ローカルの install では人間向けの案内だけを出す)
emit_outputs() {
    local sink="${1:-}"
    if [[ -z "${GITHUB_OUTPUT:-}" && "${sink}" != "stdout" ]]; then
        return 0
    fi
    set_output otp_version "${OTP_VERSION_RESOLVED}"
    set_output aws_lc_version "${AWS_LC_VERSION_RESOLVED}"
    set_output install_root "${INSTALL_ROOT}"
    set_output plt_path "${PLT_PATH}"
}

detect_target() {
    if [[ -n "${INPUT_OTP_TARGET:-}" ]]; then
        printf '%s\n' "${INPUT_OTP_TARGET}"
        return
    fi
    if [[ -n "${RUNNER_OS:-}" || -n "${RUNNER_ARCH:-}" ]]; then
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
        return
    fi
    local os
    local machine
    os="$(uname -s)"
    machine="$(uname -m)"
    case "${os}:${machine}" in
        Linux:x86_64)
            printf '%s\n' 'x86_64-unknown-linux-gnu'
            ;;
        Linux:aarch64 | Linux:arm64)
            printf '%s\n' 'aarch64-unknown-linux-gnu'
            ;;
        Darwin:arm64)
            printf '%s\n' 'aarch64-apple-darwin'
            ;;
        Darwin:x86_64)
            die 'macOS x64 is not supported; only macOS arm64 (aarch64-apple-darwin) is available'
            ;;
        *)
            die "unsupported platform: ${os} ${machine}"
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

# latest は対象ターゲットの行がある中で最後 (最新) の Erlang/OTP を選ぶ
select_otp_version() {
    local file="$1"
    local target="$2"
    local requested="$3"
    if [[ "${requested}" == "latest" ]]; then
        manifest_rows "${file}" |
            awk -F'\t' -v target="${target}" '
                NF >= 6 && $3 == target {
                    found = $1
                }
                END {
                    print found
                }'
        return
    fi
    manifest_rows "${file}" |
        awk -F'\t' -v req="${requested}" '
            NF >= 6 && $1 == req {
                found = $1
            }
            END {
                print found
            }'
}

# latest (または未指定) は対象ターゲットの行がある中で最後 (最新) の AWS-LC を選ぶ
select_aws_lc_version() {
    local file="$1"
    local otp_version="$2"
    local target="$3"
    local requested="$4"
    if [[ -z "${requested}" || "${requested}" == "latest" ]]; then
        manifest_rows "${file}" |
            awk -F'\t' -v otp="${otp_version}" -v target="${target}" '
                NF >= 6 && $1 == otp && $3 == target {
                    found = $2
                }
                END {
                    print found
                }'
        return
    fi
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

install_base() {
    if [[ -n "${SETUP_ERLANG_ROOT:-}" ]]; then
        printf '%s\n' "${SETUP_ERLANG_ROOT}"
    elif [[ -n "${RUNNER_TOOL_CACHE:-}" ]]; then
        printf '%s\n' "${RUNNER_TOOL_CACHE}/setup-erlang"
    else
        local data_home="${XDG_DATA_HOME:-}"
        if [[ -z "${data_home}" ]]; then
            [[ -n "${HOME:-}" ]] || die 'HOME or XDG_DATA_HOME is required to determine the install directory'
            data_home="${HOME}/.local/share"
        fi
        printf '%s\n' "${data_home}/setup-erlang"
    fi
}

install_root_for() {
    local otp_version="$1"
    local aws_lc_version="$2"
    printf '%s\n' "$(install_base)/${otp_version}-aws-lc-${aws_lc_version}"
}

current_link() {
    printf '%s\n' "$(install_base)/current"
}

plt_path_for() {
    local install_root="$1"
    local otp_version="$2"
    printf '%s\n' "${install_root}/plt/rebar3_${otp_version}_iplt"
}

resolve_versions() {
    local manifest
    manifest="$(manifest_path)"
    [[ -f "${manifest}" ]] || die "manifest not found: ${manifest}"
    if [[ -z "$(manifest_rows "${manifest}")" ]]; then
        die "no builds are registered in ${manifest}; run the Build Erlang/OTP workflow first"
    fi

    TARGET="$(detect_target)"

    local requested_otp="${INPUT_OTP_VERSION:-}"
    if [[ -z "${requested_otp}" || "${requested_otp}" == "latest" ]]; then
        [[ "${ACTION_MODE}" == "false" ]] ||
            die 'otp-version is required in GitHub Actions and must be an exact version (example: 29.1.1)'
        requested_otp="latest"
    fi

    OTP_VERSION_RESOLVED="$(select_otp_version "${manifest}" "${TARGET}" "${requested_otp}")"
    if [[ -z "${OTP_VERSION_RESOLVED}" ]]; then
        if [[ "${requested_otp}" == "latest" ]]; then
            die "no Erlang/OTP build is registered for ${TARGET}"
        fi
        die "no Erlang/OTP build matches otp-version '${requested_otp}' (available: $(available_otp_versions "${manifest}"))"
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
    PLT_ASSET="$(printf '%s' "${row}" | cut -f7)"
    PLT_SHA256="$(printf '%s' "${row}" | cut -f8)"
    if [[ "${INPUT_USE_PLT:-true}" == "true" && -z "${PLT_ASSET}" ]]; then
        die "no PLT asset is registered for Erlang/OTP ${OTP_VERSION_RESOLVED} + AWS-LC ${AWS_LC_VERSION_RESOLVED} on ${TARGET}; run the Build Erlang/OTP workflow with plt_only to add one"
    fi
    RELEASE_TAG="otp-${OTP_VERSION_RESOLVED}-aws-lc-${AWS_LC_VERSION_RESOLVED}"
    DOWNLOAD_URL="${RELEASE_BASE_URL}/${RELEASE_TAG}/${ASSET}"
    PLT_URL="${RELEASE_BASE_URL}/${RELEASE_TAG}/${PLT_ASSET}"
    INSTALL_ROOT="$(install_root_for "${OTP_VERSION_RESOLVED}" "${AWS_LC_VERSION_RESOLVED}")"
    PLT_PATH="$(plt_path_for "${INSTALL_ROOT}" "${OTP_VERSION_RESOLVED}")"
}

# Ubuntu 22.04 以前 (glibc < 2.38) ではプリビルドバイナリが動かないため、
# ダウンロードの前に分かりやすく失敗させる
check_linux_glibc() {
    [[ "$(uname -s)" == 'Linux' ]] || return 0
    command -v ldd >/dev/null 2>&1 || return 0
    local running
    running="$(ldd --version 2>/dev/null | awk 'NR == 1 {
        for (i = 1; i <= NF; i++) {
            if ($i ~ /^[0-9]+\.[0-9]+$/) {
                print $i
                exit
            }
        }
    }')"
    if [[ -z "${running}" ]]; then
        die 'glibc is required; this Linux does not look like a glibc system (Ubuntu 24.04 or newer is supported)'
    fi
    if ! awk -v running="${running}" \
        -v required_major="${GLIBC_REQUIRED_MAJOR}" \
        -v required_minor="${GLIBC_REQUIRED_MINOR}" '
        BEGIN {
            split(running, part, ".")
            if (part[1] > required_major) {
                exit 0
            }
            if (part[1] == required_major && part[2] >= required_minor) {
                exit 0
            }
            exit 1
        }'; then
        die "glibc ${running} is too old; glibc ${GLIBC_REQUIRED_MAJOR}.${GLIBC_REQUIRED_MINOR} or newer is required (Ubuntu 24.04 or newer is supported)"
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
        die "sha256 mismatch for $(basename "${file}"): expected ${expected}, actual ${actual}"
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
        "${erl_bin}" -noshell -eval '{ok, _} = application:ensure_all_started(crypto), [{_, _, VersionString} | _] = crypto:info_lib(), io:format("~s~n", [VersionString]), halt().' 2>&1
    )"; then
        if [[ "${output}" == *GLIBC_* ]]; then
            die "Erlang/OTP failed to start: ${output}
glibc ${GLIBC_REQUIRED_MAJOR}.${GLIBC_REQUIRED_MINOR} or newer is required (Ubuntu 24.04 or newer is supported)"
        fi
        die "Erlang/OTP failed to start: ${output}"
    fi
    case "${output}" in
        *AWS-LC*) ;;
        *) die "crypto is not linked against AWS-LC: ${output}" ;;
    esac
    printf 'setup-erlang: crypto backend is %s\n' "${output}"
}

verify_plt() {
    local file="$1"
    local erl_bin="${INSTALL_ROOT}/bin/erl"
    [[ -x "${erl_bin}" ]] || die "erl is not installed at ${erl_bin}"
    local output
    if ! output="$(
        PLT_FILE="${file}" "${erl_bin}" -noshell -eval '
            case dialyzer:plt_info(os:getenv("PLT_FILE")) of
                {ok, {incremental, [{modules, Modules}]}} ->
                    io:format("~b", [length(Modules)]),
                    halt(0);
                Other ->
                    io:format(standard_error, "~p~n", [Other]),
                    halt(1)
            end.' 2>&1
    )"; then
        die "the base PLT is not a valid incremental PLT: ${file} (${output})"
    fi
    printf 'setup-erlang: the base PLT contains %s modules\n' "${output}"
}

# rebar3 は releases/<major>/OTP_VERSION の中身を PLT のファイル名に使う
installed_otp_release() {
    local version_file
    for version_file in "${INSTALL_ROOT}"/releases/*/OTP_VERSION; do
        if [[ -f "${version_file}" ]]; then
            tr -d '\r\n' < "${version_file}"
            return 0
        fi
    done
    printf '%s' "${OTP_VERSION_RESOLVED}"
}

install_plt() {
    PLT_PATH="$(plt_path_for "${INSTALL_ROOT}" "$(installed_otp_release)")"
    local installed_name
    installed_name="$(basename "${PLT_PATH}")"
    if [[ -s "${PLT_PATH}" ]]; then
        printf 'setup-erlang: the base PLT is already installed at %s\n' "${PLT_PATH}"
    else
        local tmp_dir
        tmp_dir="$(mktemp -d)"
        local downloaded="${tmp_dir}/${PLT_ASSET}"
        download_file "${PLT_URL}" "${downloaded}"
        verify_sha256 "${downloaded}" "${PLT_SHA256}"
        verify_plt "${downloaded}"
        mkdir -p "$(dirname "${PLT_PATH}")"
        mv "${downloaded}" "${PLT_PATH}"
        chmod 0644 "${PLT_PATH}"
        rm -rf "${tmp_dir}"
    fi

    # rebar3 がデフォルトで読む場所にも毎回コピーする
    # (GitHub hosted runner では $HOME が毎回消えるため)
    [[ -n "${HOME:-}" ]] || die 'HOME is required to install the base PLT'
    local rebar3_cache_dir="${HOME}/.cache/rebar3"
    local rebar3_plt="${rebar3_cache_dir}/${installed_name}"
    mkdir -p "${rebar3_cache_dir}"
    local tmp_plt="${rebar3_plt}.tmp.$$"
    cp "${PLT_PATH}" "${tmp_plt}"
    chmod 0644 "${tmp_plt}"
    mv "${tmp_plt}" "${rebar3_plt}"
    printf 'setup-erlang: installed the base PLT at %s\n' "${rebar3_plt}"
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

# current は相対 symlink にしておく (base ごと移動しても壊れない)
update_current_link() {
    local base
    local target
    base="$(install_base)"
    target="${OTP_VERSION_RESOLVED}-aws-lc-${AWS_LC_VERSION_RESOLVED}"
    mkdir -p "${base}"
    ln -sfn "${target}" "${base}/current"
    printf 'setup-erlang: %s -> %s\n' "${base}/current" "${target}"
}

is_on_path() {
    local directory="$1"
    local entry
    local path="${PATH:-}"
    local IFS=':'
    for entry in ${path}; do
        if [[ "${entry}" == "${directory}" ]]; then
            return 0
        fi
    done
    return 1
}

shell_profile_hint() {
    # シェルの設定ファイルはチルダのまま表示したい
    # shellcheck disable=SC2088
    case "${SHELL:-}" in
        */zsh)
            printf '%s\n' '~/.zshrc'
            ;;
        */bash)
            printf '%s\n' '~/.bashrc'
            ;;
        *) printf '%s\n' 'your shell profile' ;;
    esac
}

print_path_hint() {
    local bin="$1"
    if is_on_path "${bin}"; then
        printf 'setup-erlang: %s is already on PATH; run "erl" to start it\n' "${bin}"
        return
    fi
    printf 'setup-erlang: add the following line to your shell profile (%s):\n' "$(shell_profile_hint)"
    # $PATH は展開させず、そのままコピーしてもらう
    # shellcheck disable=SC2016
    printf '\n  export PATH="%s:$PATH"\n\n' "${bin}"
    printf 'setup-erlang: then run "erl" (restart the shell or source the profile first)\n'
}

list_command() {
    local base
    base="$(install_base)"
    local current_target=""
    if [[ -L "${base}/current" ]]; then
        current_target="$(basename "$(readlink "${base}/current")")"
    fi
    printf 'setup-erlang: installed under %s\n' "${base}"
    local found=false
    local dir
    local name
    for dir in "${base}"/*; do
        [[ -d "${dir}" && ! -L "${dir}" ]] || continue
        name="$(basename "${dir}")"
        found=true
        if [[ "${name}" == "${current_target}" ]]; then
            printf '  * %s\n' "${name}"
        else
            printf '    %s\n' "${name}"
        fi
    done
    if [[ "${found}" == "false" ]]; then
        printf '  (none)\n'
    fi

    local manifest
    manifest="$(manifest_path)"
    TARGET="$(detect_target)"
    printf 'setup-erlang: available for %s\n' "${TARGET}"
    manifest_rows "${manifest}" |
        awk -F'\t' -v target="${TARGET}" '
            NF >= 6 && $3 == target {
                if (!($1 in seen)) {
                    seen[$1] = 1
                    order[++count] = $1
                }
                key = $1 SUBSEP $2
                if (!(key in pair)) {
                    pair[key] = 1
                    versions[$1] = versions[$1] " " $2
                }
            }
            END {
                for (i = count; i >= 1; i--) {
                    v = versions[order[i]]
                    sub(/^ /, "", v)
                    printf "  %s  %s\n", order[i], v
                }
            }'
}

use_command() {
    [[ -n "${USE_VERSION}" ]] || die 'usage: install.sh use <otp-version> [aws-lc-version]'
    [[ "${USE_VERSION}" != "latest" ]] ||
        die 'use requires an exact version; run "install.sh list" to see the installed versions'

    local base
    base="$(install_base)"
    local candidate=""
    if [[ -n "${USE_AWS_LC_VERSION}" ]]; then
        local name
        for name in "${USE_VERSION}-aws-lc-${USE_AWS_LC_VERSION}" "${USE_VERSION}-aws-lc-v${USE_AWS_LC_VERSION}"; do
            if [[ -d "${base}/${name}" ]]; then
                candidate="${name}"
                break
            fi
        done
    else
        local matches=()
        local dir
        for dir in "${base}/${USE_VERSION}-aws-lc-"*; do
            [[ -d "${dir}" && ! -L "${dir}" ]] || continue
            matches+=("$(basename "${dir}")")
        done
        if (( ${#matches[@]} == 1 )); then
            candidate="${matches[0]}"
        elif (( ${#matches[@]} > 1 )); then
            printf 'setup-erlang: multiple AWS-LC versions are installed for Erlang/OTP %s:\n' "${USE_VERSION}" >&2
            printf '  %s\n' "${matches[@]}" >&2
            die "specify the AWS-LC version: install.sh use ${USE_VERSION} <aws-lc-version>"
        fi
    fi
    [[ -n "${candidate}" ]] ||
        die "Erlang/OTP ${USE_VERSION} is not installed under ${base}; run \"install.sh list\" to see the installed versions"

    mkdir -p "${base}"
    ln -sfn "${candidate}" "${base}/current"
    printf 'setup-erlang: %s -> %s\n' "${base}/current" "${candidate}"
    print_path_hint "${base}/current/bin"
}

resolve_command() {
    resolve_versions
    emit_outputs stdout
    printf 'setup-erlang: resolved Erlang/OTP %s with AWS-LC %s for %s (source %s)\n' \
        "${OTP_VERSION_RESOLVED}" "${AWS_LC_VERSION_RESOLVED}" "${TARGET}" "${SOURCE_REF}"
}

install_command() {
    check_linux_glibc
    resolve_versions
    if [[ -f "${INSTALL_ROOT}/.setup-erlang-complete" ]]; then
        printf 'setup-erlang: Erlang/OTP %s with AWS-LC %s is already installed at %s\n' \
            "${OTP_VERSION_RESOLVED}" "${AWS_LC_VERSION_RESOLVED}" "${INSTALL_ROOT}"
    else
        install_archive
    fi
    add_to_path "${INSTALL_ROOT}/bin"
    verify_installation
    if [[ "${INPUT_USE_PLT:-true}" == "true" ]]; then
        install_plt
    fi
    emit_outputs
    printf 'setup-erlang: installed Erlang/OTP %s with AWS-LC %s at %s\n' \
        "${OTP_VERSION_RESOLVED}" "${AWS_LC_VERSION_RESOLVED}" "${INSTALL_ROOT}"
    if [[ "${ACTION_MODE}" == "false" ]]; then
        update_current_link
        print_path_hint "$(current_link)/bin"
    fi
}

# コマンドとオプションを解釈する。オプションは環境変数より優先され、
# install / resolve ではバージョンを位置引数でも指定できる
parse_args() {
    local positional=()
    while (( $# > 0 )); do
        case "$1" in
            install | resolve | list | use | help)
                COMMAND="$1"
                shift
                ;;
            -h | --help)
                COMMAND=help
                shift
                ;;
            --otp-version)
                [[ $# -ge 2 ]] || die '--otp-version requires a value'
                INPUT_OTP_VERSION="$2"
                shift 2
                ;;
            --otp-version=*)
                INPUT_OTP_VERSION="${1#*=}"
                shift
                ;;
            --aws-lc-version)
                [[ $# -ge 2 ]] || die '--aws-lc-version requires a value'
                INPUT_AWS_LC_VERSION="$2"
                shift 2
                ;;
            --aws-lc-version=*)
                INPUT_AWS_LC_VERSION="${1#*=}"
                shift
                ;;
            --target)
                [[ $# -ge 2 ]] || die '--target requires a value'
                INPUT_OTP_TARGET="$2"
                shift 2
                ;;
            --target=*)
                INPUT_OTP_TARGET="${1#*=}"
                shift
                ;;
            --root)
                [[ $# -ge 2 ]] || die '--root requires a value'
                SETUP_ERLANG_ROOT="$2"
                shift 2
                ;;
            --root=*)
                SETUP_ERLANG_ROOT="${1#*=}"
                shift
                ;;
            --no-plt)
                INPUT_USE_PLT=false
                shift
                ;;
            --)
                shift
                while (( $# > 0 )); do
                    positional+=("$1")
                    shift
                done
                ;;
            -*)
                usage >&2
                die "unknown option: $1"
                ;;
            *)
                positional+=("$1")
                shift
                ;;
        esac
    done

    case "${COMMAND}" in
        install | resolve)
            if (( ${#positional[@]} > 2 )); then
                usage >&2
                die 'too many arguments'
            fi
            if (( ${#positional[@]} >= 1 )) && [[ -z "${INPUT_OTP_VERSION:-}" ]]; then
                INPUT_OTP_VERSION="${positional[0]}"
            fi
            if (( ${#positional[@]} >= 2 )) && [[ -z "${INPUT_AWS_LC_VERSION:-}" ]]; then
                INPUT_AWS_LC_VERSION="${positional[1]}"
            fi
            ;;
        use)
            if (( ${#positional[@]} >= 1 )); then
                USE_VERSION="${positional[0]}"
            fi
            if (( ${#positional[@]} >= 2 )); then
                USE_AWS_LC_VERSION="${positional[1]}"
            fi
            if (( ${#positional[@]} > 2 )); then
                usage >&2
                die 'too many arguments'
            fi
            ;;
        *)
            if (( ${#positional[@]} > 0 )); then
                usage >&2
                die "unexpected argument: ${positional[0]}"
            fi
            ;;
    esac
}

main() {
    parse_args "$@"
    case "${COMMAND}" in
        install)
            install_command
            ;;
        resolve)
            resolve_command
            ;;
        list)
            list_command
            ;;
        use)
            use_command
            ;;
        help)
            usage
            ;;
        *)
            usage >&2
            die "unknown command: ${COMMAND}"
            ;;
    esac
}

# 実行時 (curl | bash を含む) だけ main を呼ぶ。source された場合は呼ばない
if [[ -z "${BASH_SOURCE[0]:-}" || "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
