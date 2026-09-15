# Erlang/OTP ビルド済みバイナリを使う GitHub Action

## 使い方

```yaml
- uses: shiguredo/setup-erlang@main
  with:
    otp-version: "29.0.6"
    aws-lc-version: "v5.8.0"
```

- ビルド済みの tar.gz をダウンロードしてインストールするだけです
- `otp-version` は `latest` / `29` / `29.0` / `29.0.6` が使えます
- `aws-lc-version` は省略できます。省略時はその Erlang/OTP で利用できる最新の AWS-LC を使います
- 利用できるバージョンは [versions/builds.tsv](versions/builds.tsv) にあります

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
