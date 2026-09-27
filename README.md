# Erlang/OTP ビルド済みバイナリをインストールする

AWS-LC を静的リンクしたビルド済み Erlang/OTP をインストールします。GitHub Actions の composite action と、Ubuntu / macOS のインストーラーとして使えます。

- ビルド済みの tar.gz をダウンロードして展開するだけです
- dialyzer のベース PLT もダウンロードして `~/.cache/rebar3` に配置します (無効にするには `--no-plt` または `use-plt: "false"` を指定します)
- 利用できるバージョンは [versions/builds.tsv](versions/builds.tsv) にあります

## GitHub Actions で使う

```yaml
- uses: shiguredo/setup-erlang@main
  with:
    otp-version: "29.1.1"
    aws-lc-version: "v5.10.0"
```

- `otp-version` は完全一致で指定します (例: `29.1.1`)
- `aws-lc-version` は省略できます。省略時はその Erlang/OTP で利用できる最新の AWS-LC を使います

### キャッシュと dialyzer のベース PLT

```yaml
- uses: shiguredo/setup-erlang@main
  with:
    otp-version: "29.1.1"
    aws-lc-version: "v5.10.0"
    use-cache: "true"
```

- `use-cache` を有効にするとインストールディレクトリを actions/cache でキャッシュします
- self-hosted runner では actions/cache を使いません
  - `RUNNER_TOOL_CACHE` 配下が runner に残るため、2 回目以降はインストール済みの Erlang/OTP をそのまま使います
- `use-plt` はデフォルトで有効です。リリースに同梱された dialyzer のベース PLT (incremental) をダウンロードし、rebar3 が読む場所 (`~/.cache/rebar3/rebar3_<OTP_VERSION>_iplt`) に配置します
  - 無効にするには `use-plt: "false"` を指定します
  - 対象のアプリは rebar3 のデフォルトと同じ `erts crypto kernel stdlib` です
  - PLT のパスは `plt-path` 出力で参照できます
  - rebar3 のデフォルト設定 (`base_plt_location: global`、`base_plt_prefix: rebar3`) が前提です
- dialyzer の incremental モードは、ベース PLT に記録された `warnings` 設定とプロジェクトの `warnings` 設定が完全一致しない場合、差分ではなく全ファイルを解析します
  - `warnings` をカスタムしているプロジェクトでは、GitHub hosted runner で project PLT (`_build/default/rebar3_*.iplt`) を actions/cache で保存すると 2 回目以降が速くなります
  - self-hosted runner では `_build` が残るため追加のキャッシュは不要です

### 出力

- `otp-version`: インストールした Erlang/OTP のバージョン
- `aws-lc-version`: インストールした AWS-LC のバージョン
- `erlang-root-dir`: Erlang/OTP のインストールディレクトリ
- `plt-path`: dialyzer のベース PLT のパス (`use-plt` が有効な場合のみファイルが存在します)

## Ubuntu / macOS で使う

```console
$ curl -fsSL https://raw.githubusercontent.com/shiguredo/setup-erlang/main/scripts/install.sh | bash
```

- GitHub Actions 以外では `otp-version` を省略できます。省略時は対応する最新の Erlang/OTP と AWS-LC をインストールします
- インストール先は `${XDG_DATA_HOME:-$HOME/.local/share}/setup-erlang` です
  - 変更するには `--root` を指定するか、`SETUP_ERLANG_ROOT` を設定します
- インストールすると `<root>/current` がインストールしたバージョンへのシンボリックリンクになります

```console
# バージョンを指定してインストールする
$ curl -fsSL https://raw.githubusercontent.com/shiguredo/setup-erlang/main/scripts/install.sh | bash -s -- 29.1.1

# AWS-LC も指定してインストールする
$ curl -fsSL https://raw.githubusercontent.com/shiguredo/setup-erlang/main/scripts/install.sh | bash -s -- 29.1.1 v5.10.0
```

インストールの最後に表示される `export PATH` をシェルの設定ファイルに追加すると `erl` が使えるようになります。

```console
$ export PATH="$HOME/.local/share/setup-erlang/current/bin:$PATH"
$ erl -noshell -eval 'io:format("~s~n", [erlang:system_info(otp_release)]), halt().'
```

- `erl` は `$0` の位置からルートディレクトリを探すため、`bin/erl` 単位のシンボリックリンクでは動きません。`current` のディレクトリ単位のシンボリックリンクを PATH に通してください

### バージョンの確認と切り替え

スクリプトを保存しておくと `list` と `use` が使えます。

```console
$ curl -fsSL -o setup-erlang.sh https://raw.githubusercontent.com/shiguredo/setup-erlang/main/scripts/install.sh
$ bash setup-erlang.sh list
setup-erlang: installed under /Users/example/.local/share/setup-erlang
  * 29.1.1-aws-lc-v5.10.0
setup-erlang: available for aarch64-apple-darwin
  29.1.1  v5.9.0 v5.10.0
  29.1  v5.9.0
  29.0.6  v5.8.0
$ bash setup-erlang.sh use 29.1.1 v5.10.0
```

- `list` はインストール済みのバージョン (先頭の `*` が `current`) と、その環境で利用できるバージョンを表示します
- `use` はインストール済みのバージョンへ `current` を切り替えます

### オプションと環境変数

- `--otp-version` / `INPUT_OTP_VERSION`: Erlang/OTP のバージョン (例: `29.1.1`)
- `--aws-lc-version` / `INPUT_AWS_LC_VERSION`: AWS-LC のバージョン (例: `v5.10.0`)
- `--target` / `INPUT_OTP_TARGET`: ターゲットトリプル。通常は自動検出します
- `--root` / `SETUP_ERLANG_ROOT`: インストール先
- `--no-plt` / `INPUT_USE_PLT`: dialyzer のベース PLT をインストールしません
- `SETUP_ERLANG_MANIFEST`: マニフェストファイルを直接指定します
- `SETUP_ERLANG_MANIFEST_URL`: マニフェストの URL を指定します (既定は `raw.githubusercontent.com/shiguredo/setup-erlang/main/versions/builds.tsv`)
- `SETUP_ERLANG_MANIFEST_REF`: マニフェストを取得する ref を指定します (既定は `main`)

## 対応プラットフォーム

- Ubuntu x86_64
  - 26.04
  - 24.04
- Ubuntu arm64
  - 26.04
  - 24.04
- macOS arm64
  - 26

ビルド済みバイナリは glibc 2.38 以降が必要です。Ubuntu 22.04 以前では動作しません。macOS の x86_64 には対応していません。

## AWS-LC パッチ

- [AWS-LC](https://github.com/aws/aws-lc) を静的リンクした Erlang/OTP を提供しています
- [shiguredo/otp](https://github.com/shiguredo/otp) の `aws-lc-OTP-*` タグからビルドしています
- ビルドオプションは [docker-erlang-otp](https://github.com/shiguredo/docker-erlang-otp) と同じです

## 管理ポリシー

- GitHub Actions と Ubuntu / macOS 向けのビルド済み Erlang/OTP
- Erlang/OTP のリリースに追従していく

## ライセンス

Apache License 2.0

```text
Copyright 2026 Shiguredo Inc.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```
