# Erlang/OTP ビルド済みバイナリを使う GitHub Action

## 使い方

```yaml
- uses: shiguredo/setup-erlang@main
  with:
    otp-version: "29.1"
    aws-lc-version: "v5.9.0"
```

- ビルド済みの tar.gz をダウンロードしてインストールするだけです
- dialyzer のベース PLT もダウンロードして `~/.cache/rebar3` に配置します（無効にするには `use-plt: "false"` を指定します）
- `otp-version` は完全一致で指定します（例: `29.1`）
- `aws-lc-version` は省略できます。省略時はその Erlang/OTP で利用できる最新の AWS-LC を使います
- 利用できるバージョンは [versions/builds.tsv](versions/builds.tsv) にあります

## キャッシュと dialyzer のベース PLT

```yaml
- uses: shiguredo/setup-erlang@main
  with:
    otp-version: "29.1"
    aws-lc-version: "v5.9.0"
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
- dialyzer の incremental モードは、ベース PLT に記録された `warnings` 設定とプロジェクトの `warnings` 設定が完全一致しないとフル解析になります
  - `warnings` をカスタムしているプロジェクトでは、GitHub hosted runner で project PLT (`_build/default/rebar3_*.iplt`) を actions/cache で保存すると 2 回目以降が速くなります
  - self-hosted runner では `_build` が残るため追加のキャッシュは不要です

## 対応プラットフォーム

- Ubuntu x86_64
  - 26.04
  - 24.04
- Ubuntu arm64
  - 26.04
  - 24.04
- macOS arm64
  - 26

## AWS-LC パッチ

- [AWS-LC](https://github.com/aws/aws-lc) を静的リンクした Erlang/OTP を提供しています
- [shiguredo/otp](https://github.com/shiguredo/otp) の `aws-lc-OTP-*` タグからビルドしています
- ビルドオプションは [docker-erlang-otp](https://github.com/shiguredo/docker-erlang-otp) と同じです

## 管理ポリシー

- GitHub Actions 向けのビルド済み Erlang/OTP
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
