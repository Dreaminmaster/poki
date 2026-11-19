# Poki iPhone アプリガイド

[English](iphone-guide.md) | [简体中文](iphone-guide.zh-CN.md) | [繁體中文](iphone-guide.zh-TW.md) | 日本語 | [한국어](iphone-guide.ko.md) | [Español](iphone-guide.es.md)

このガイドでは、Poki iPhone アプリのシステム要件、インストールの詳細、アップデート方法、よくある質問、既知の制限、タスクの例を説明します。

各バージョンの変更は [CHANGELOG.md](../CHANGELOG.md) をご覧ください。

## 必要なもの

| 項目 | 要件 |
| --- | --- |
| iPhone | iOS 18 以降（iPhone XS、XR、SE 第 2 世代以降）。実機テストは iOS 27 の iPhone で行っています。 |
| パソコン | macOS 14 以降の Mac（エージェント導入には Node.js 24 以降）、または Apple Devices か iTunes を導入した Windows PC（x64）。 |
| ケーブルとアカウント | USB データケーブルと Apple Account。無料アカウントの署名は 7 日間有効で、Poki Setup または Poki アプリ内で更新できます。 |
| 接続 | `10.7.0.1` を iPhone に戻す外部接続（無料の LocalDevVPN や、Poki の案内に沿って設定した Karing、Shadowrocket）。 |
| モデルアカウント | ご自身で用意します。ChatGPT Plus または Pro でのログインが手軽です。Anthropic、OpenAI、Gemini、DeepSeek、OpenRouter、OpenCode Go の API キーや、独自の OpenAI 互換サーバーも使えます。Claude のサブスクリプションではログインできないため、Anthropic の API キーを使ってください。 |

iOS 27 以降ではネイティブサービスで iPhone を操作します。iOS 18 から 26 では XCTest セッションを使うため、iPhone のデベロッパ設定で UI オートメーションを有効にしてください。iPadOS 18 以降の iPad にもインストールできます。

iPhone アプリには自分のモデルアカウントを使います。コーディングエージェントの契約が Poki に自動で引き継がれるわけではありません。既存のエージェントで Poki MCP だけを使う場合は、[MCP のインストール手順](install.md)に従ってください。MCP はそのクライアントのモデル接続を使います。

## インストール手順

### ワンクリックインストール（推奨）

あなたが行うのは、iPhone の接続とロック解除、案内に従ったログイン、iPhone の権限、ローカル接続、モデルアカウントの設定だけです。

Claude Code や Codex などのエージェントに、次のように伝えます。

```text
Install Poki on my iPhone from https://github.com/JosssphZhou/poki
```

エージェントは [install-poki スキル](../skills/install-poki/SKILL.md)に従い、`bin/install-iphone.mjs` で自動化できる手順を進めます。あなたが行うのは、Mac の Poki Setup 画面での Apple Account 入力、iPhone での「信頼」、デベロッパモードの有効化、開発者の信頼、Poki の起動です。初回起動でオートメーションモードを求められたら「続ける」をタップし、iPhone のパスコードを入力します。キャンセルした場合は、Poki を再び有効にすると確認が表示されます。操作が必要になるたびに、エージェントが案内します。無料の Apple Account も使えます。

現在のインストーラは Beta を選びます。以前の Stable、Alpha、Pre-alpha の設定も Beta として扱い、Beta がなければ停止します。インストール済みの古い Poki Setup は以前の選択方法を使う場合があるため、今回表示されたバージョンを確認してください。

Node.js 24 がない場合や Windows でも、Poki Setup をインストールすれば同じ依頼文を使えます。エージェントが内蔵のコマンドラインツールを使います。依頼文は Poki Setup のメニューからもコピーできます。Mac は `Poki > Copy Prompt for Your Agent`、Windows は `Settings > Use an agent` です。

リリース情報の取得中に GitHub が 403 や 429 を返す場合、同じネットワークで共有する匿名リクエストの時間単位の上限が原因であることが多いです。別のネットワークやプロキシ接続先で再試行するか、1 時間待ってください。

### Poki Setup を使う

インストーラを含む最新の [Beta リリース](https://github.com/JosssphZhou/poki/releases)から macOS 版（`.dmg`）または Windows 版（`.exe`、[ZhehanZhang](https://github.com/ZhehanZhang) が提供）の Poki Setup をダウンロードし、画面の案内に従ってください。詳しくは [Poki Setup](../desktop/README.md) をご覧ください。

### 最初のタスクを実行する

インストールされたバージョンを確認し、ローカル接続とモデルアカウントの設定を終えたら、Poki で次の依頼を送信します。

```text
Create a new note in Notes titled "Poki Demo" with these three lines: Milk, Eggs, Coffee. Open the note when finished. Leave existing notes unchanged.
```

メモアプリで、タイトルが「Poki Demo」、本文の各行が Milk、Eggs、Coffee になっていることを確認します。完了メッセージだけでは成功の証明になりません。メモアプリがない場合や設定が未完了の場合は、先にその手順を完了してください。中断後に再試行する前には、メモが作成済みか確認してください。

## よくある質問

**Windows からインストールできますか？** はい。Windows 版 Poki Setup は Mac 版と同様にインストール、ペアリング、署名更新に対応しています。先に Apple Devices または iTunes を入れ、iPhone を認識できるようにしてください。[Poki Setup](../desktop/README.md) をご覧ください。

**インストール後もパソコンが必要ですか？** 作業は iPhone だけで実行できます。無料の Apple Account では、パソコンの Poki Setup を起動して署名を更新するか、Poki 内で Apple Account にログインして iPhone 自身で更新します。ログインできない場合はパソコンの Poki Setup を使ってください。[起動しておくもの](../skills/install-poki/SKILL.md#what-to-keep-running)をご覧ください。

**無料の Apple Account で使えますか？7 日間の制限とは何ですか？** 使えますが、署名の有効期間は 7 日間です。Poki Setup が起動中で、パソコンがスリープせず iPhone に接続できる場合、6 時間ごとに確認し、残り 2 日以下になったアプリの署名を更新します。期限が切れるとアプリを開けなくなるため、Poki は最後の 2 日間に警告します。[有料の開発者アカウントがない場合](../skills/install-poki/SKILL.md#no-paid-developer-account)をご覧ください。

**どの iPhone と iOS が必要ですか？** iOS 18 以降の iPhone XS、XR、SE（第 2 世代）以降です。iPadOS 18 以降の iPad にもインストールできます。実機テストは iOS 27 で行っており、別の操作方式を使う iOS 18 から 26 は実機未検証です。[検証結果と既知の制限](verification.md)をご覧ください。

**自分のモデルアカウントが必要ですか？** はい。ChatGPT Plus または Pro でログインするか、Anthropic、OpenAI、Gemini、DeepSeek、OpenRouter、OpenCode Go の API キー、または独自の OpenAI 互換サーバーを使います。音声会話には音声モデルのキーも必要です。[必要なもの](#必要なもの)をご覧ください。

**中国本土のネットワークなどで更新が表示されない場合は？** 更新の確認先は GitHub です。接続できないネットワークや、403、429 の制限に達した場合は、別のネットワークやプロキシ接続先を試すか、パソコンの Poki Setup で Renew を使ってください。[Poki を更新する](#poki-を更新する)をご覧ください。

**iPhone の内容を変更しますか？操作前に確認しますか？** 実際のアプリでメッセージ送信などの依頼を実行し、画面内容を設定済みのモデルサービスに送ります。支払い、削除、ウォレット内の操作には必ず確認が必要です。メッセージ送信やパスワード入力など、ほかの慎重に扱う操作では、`Settings > Approvals` で確認方法や確認の有無を選べます。[既知の問題](#既知の問題)をご覧ください。

## Poki を更新する

- **iPhone で更新。** 現在のビルドでは `Settings > Signing & Updates` を開きます。古いビルドでは「Connection」の下にある場合があります。新しいビルドがあればダウンロードとインストールを選べます。ログインを求められた場合は、パソコンからインストールしたため iPhone に Apple Account が保存されていません。インストール時のアカウントでログインするか、パソコンから更新してください。
- **パソコンで更新。** Poki Setup の Renew は選択中のチャンネルの最新ビルドを既存アプリに上書きインストールします。Mac ではエージェントに「iPhone の Poki を更新して」と頼むこともできます。install-poki スキルの更新手順は、先に現在のバージョンと署名の識別情報を確認します。
- 「Finishing the update」で止まったら、アプリスイッチャーで Poki を終了して開き直し、設定でバージョンを確認してください。変わっていなければパソコンの Poki Setup から更新します。更新の修復のために Poki を削除しないでください。会話も消えます。

チャンネルと Alpha から Beta への移行は[リリースチャンネル](release-channels.md)をご覧ください。

## タスクを試す

Poki を開き、「明日の天気を調べて、傘が必要か教えて」のように入力するか、ホーム画面のアプリをタップして作業を始めます。Poki は画面上のアプリを操作し、Dynamic Island とロック画面に手順を表示し、設定に従って承認を求めます。

Poki を開かずに呼び出すこともできます。アクションボタンを長押しして話すか、ショートカットや Siri から Talk to Poki または Send Task to Poki を使います。この方法で送ったタスクの結果は通知で届きます。iPhone Duo の Split View では、2 つのアプリを並べて Poki に操作させることができます。

> **注意：** Poki は実際の iPhone を操作します。メッセージ送信や支払いを頼めば実行します。

## 既知の問題

- Poki は実際の iPhone を操作し、依頼されたメッセージ送信や支払いを実行します。画面内容は設定したモデルサービスに送られます。
- iPhone で Apple Account にログインできない場合は、パソコンの Poki Setup で署名更新とアプリ更新を行ってください。
- 実機で検証済みなのは、中国語表示で縦向きの iPhone のみです。横向きには対応していません。
- このリリースは iOS 27 より前の iPhone 実機や iPad では未検証です。古い機種や小型の iPhone では、立体のクマとホーム画面のアニメーションによって発熱や動作の遅れが生じる可能性があります。低電力モードや「視差効果を減らす」ではクマを静止画で表示します。
- 無料の Apple Account の署名は 7 日間有効です。パソコンの Poki Setup から iPhone に接続できる状態を保つか、期限前に手動で更新してください。
- GitHub のリリース取得で 403 や 429 が返ることがあります。多くはネットワークの共有によるものです。接続先を変えるか、1 時間待って再試行してください。

そのほかの制限とテスト結果は[検証結果と既知の制限](verification.md)をご覧ください。

## ロードマップ

方向性を示しています。リリース済み機能は [CHANGELOG.md](../CHANGELOG.md) に記載しています。

**Released in 0.4 Beta**

- 初期設定後はパソコンなしで動く iPhone アプリ。ロック画面と Dynamic Island での承認。
- 無料の Apple Account を使い、Mac または Windows PC のエージェントや Poki Setup からインストール。
- iOS 27 以降でのネイティブ操作と、Poki 内蔵ブラウザでのウェブタスク。
- 立体のクマがいる新しいホーム画面、音声会話、アクションボタン、会話のアーカイブ、iPhone Duo Split View、インターフェースサイズの調整、ダークモード。

**In progress**

- アップデート配信の安定化と、アップデート処理の統一。
- インターフェースの対応言語を追加。

**Planned**

- より多くの iPhone、iOS バージョン、画面言語を実機で検証。
- モデルプロバイダーを追加。

## その他のツール

[Poki MCP](poki-mcp.md) はパソコンのエージェントを iPhone や iOS シミュレータに接続する従来のツールで、現在は更新を停止しています。

[Poki Agent](poki-mcp.md#try-a-task-with-poki-agent) は iMessage と Telegram に対応したターミナルのエージェントです。設定と使い方はリンク先のガイドにあります。

## 免責事項

Poki は独立したオープンソースプロジェクトです。Apple、OpenAI、および Poki が操作するアプリやウェブサイトの開発元とは提携関係になく、それらの承認も受けていません。iPhone は Apple Inc. の商標です。

サードパーティのアプリやウェブサイトの自動操作は、それらの利用規約に違反する可能性があります。特定のサービスで Poki を使うかどうかは、ご自身で判断してください。お使いのデバイスとアカウント上で Poki が行うこと（送信したメッセージ、加えた変更、その結果生じたアカウントの制限を含む）については、ご自身の責任となります。

Poki は AGPL-3.0 ライセンスの定めるとおり、無保証かつ「現状のまま」提供されます。

## ライセンス

Poki のコードは [AGPL-3.0-only ライセンス](../LICENSE)のもとでオープンソースとして公開されています。

Poki のクマ、アプリアイコン、その他の Poki のアートワークはこのライセンスの対象外です。Poki を紹介するためにスクリーンショットを使うことはできます。フォークには独自の名前とアートワークが必要です。詳しくは [BRAND.md](../BRAND.md) をご覧ください。

Copyright (c) 2026 Joseph Zhou (周瑟夫) and contributors. オープンソースの依存関係とサードパーティの素材には、それぞれのライセンスが適用されます。[THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md) を参照してください。コントリビュートについては [CONTRIBUTING.md](../CONTRIBUTING.md) をご覧ください。
