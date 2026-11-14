<p align="center">
  <img src="docs/images/poki-icon.png" width="72" height="72" alt="Poki icon">
</p>

<h1 align="center">Poki は、あなたと同じように iPhone を使う</h1>

<p align="center">
  <img src="docs/images/poki-home.gif" width="720" alt="Poki 公式サイトのトップページのアニメーション">
</p>

<p align="center">
  <a href="README.md">English</a> | <a href="README.zh-CN.md">简体中文</a> | <a href="README.zh-TW.md">繁體中文</a> | 日本語 | <a href="README.ko.md">한국어</a> | <a href="README.es.md">Español</a><br>
  <a href="https://poki.bot">poki.bot</a>
</p>

<!-- badges:start -->
<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-AGPL--3.0--only-blue" alt="License: AGPL-3.0-only"></a>
  <a href="https://github.com/JosssphZhou/poki/stargazers"><img src="https://img.shields.io/github/stars/JosssphZhou/poki" alt="GitHub stars"></a>
  <a href="https://github.com/JosssphZhou/poki/forks"><img src="https://img.shields.io/github/forks/JosssphZhou/poki" alt="GitHub forks"></a>
  <a href="https://github.com/JosssphZhou/poki/issues"><img src="https://img.shields.io/github/issues/JosssphZhou/poki" alt="GitHub issues"></a>
  <a href="https://github.com/JosssphZhou/poki/releases/tag/app-0.4.0-beta.1"><img src="https://img.shields.io/badge/Poki_App-0.4.0_Beta-blue" alt="Poki App 0.4.0 Beta"></a>
  <img src="https://img.shields.io/badge/platform-iOS%20%7C%20macOS%20%7C%20Windows-lightgrey" alt="Platform: iOS, macOS and Windows">
</p>
<!-- badges:end -->

Poki は iPhone を操作するアプリです。画面を読み取り、実際のアプリでタップ、文字入力、スクロールを行います。承認の求め方は選べますが、支払い、削除、ウォレット内の操作には必ず確認が必要です。

**Poki アプリ**は iPhone 本体で動きます。チャットで頼んだ作業を、ほかのアプリで実行します。Mac または Windows PC から一度インストールすれば、その後の作業にパソコンは不要です。

各バージョンの変更は [CHANGELOG.md](CHANGELOG.md) をご覧ください。

## iPhone に Poki をインストールする

初回のインストールには Mac または Windows PC が必要です。

- **Mac では**、エージェントにインストールを頼むか、macOS 版 Poki Setup をダウンロードして画面の案内に従います。
- **Windows では**、Windows 版 Poki Setup をダウンロードして画面の案内に従います。USB で iPhone を認識できるよう、先に Apple Devices または iTunes をインストールしてください。エージェントから Poki Setup 内蔵のコマンドラインツールを使うこともできます。
- **インストール後は**、iPhone だけで作業を実行できます。無料の Apple Account の署名は 7 日間有効で、パソコン上で Poki Setup を起動しておくと更新できます。[よくある質問](#よくある質問)をご覧ください。

### エージェントに頼む（推奨）

Claude Code や Codex などのエージェントに、次のように伝えます。

```text
https://github.com/JosssphZhou/poki から私の iPhone に Poki をインストールして
```

エージェントは [install-poki スキル](skills/install-poki/SKILL.md)に従い、`bin/install-iphone.mjs` で自動化できる手順を進めます。あなたが行うのは、Mac の Poki Setup 画面での Apple Account 入力、iPhone での「信頼」、デベロッパモードの有効化、開発者の信頼、Poki の起動です。初回起動でオートメーションモードを求められたら「続ける」をタップし、iPhone のパスコードを入力します。キャンセルした場合は、Poki を再び有効にすると確認が表示されます。操作が必要になるたびに、エージェントが案内します。無料の Apple Account も使えます。

インストーラは既定で Alpha チャンネルを使います。Beta などを希望する場合はエージェントに伝えてください。ビルドは先に Alpha で公開され、追加のテスト後に同じビルドが Beta に進みます。

Node.js 24 がない場合や Windows でも、Poki Setup をインストールすれば同じ依頼文を使えます。エージェントが内蔵のコマンドラインツールを使います。依頼文は Poki Setup のメニューからもコピーできます。Mac は Poki > Copy Prompt for Your Agent、Windows は Settings > Use an agent です。

リリース情報の取得中に GitHub が 403 や 429 を返す場合、同じネットワークで共有する匿名リクエストの時間単位の上限が原因であることが多いです。別のネットワークやプロキシ接続先で再試行するか、1 時間待ってください。

### Poki Setup を使う

自分で操作する場合は、[Alpha リリース](https://github.com/JosssphZhou/poki/releases/tag/app-alpha-latest)から macOS 版（`.dmg`）または Windows 版（`.exe`、[ZhehanZhang](https://github.com/ZhehanZhang) が提供）の Poki Setup をダウンロードし、画面の案内に従います。Beta リリースにも同じ Poki Setup ファイルがあります。設定でチャンネルを選ぶまでは最新の Stable を、Stable がなければ Beta をインストールします。詳しい手順は [Poki Setup](desktop/README.md) にあります。

### 必要なもの

| 項目 | 要件 |
| --- | --- |
| iPhone | iOS 18 以降。iPhone XS、XR、SE（第 2 世代）以降が対象です。実機テストは iOS 27 の iPhone で行っています。 |
| パソコン | macOS 14 以降の Mac、または Apple Devices か iTunes を導入した Windows PC（x64）。Mac でエージェントがインストールスクリプトを使う場合は Node.js 24 以降も必要です。 |
| ケーブルとアカウント | USB データケーブルと Apple Account。無料アカウントの署名は 7 日間有効で、Poki Setup が更新できます。 |
| 接続 | 10.7.0.1 への通信を iPhone 自身に戻す VPN アプリ。App Store の無料アプリ LocalDevVPN、または Poki の案内で設定した Karing や Shadowrocket を使えます。 |
| モデルのアカウント | ご自身で用意します。ChatGPT Plus または Pro でのログインが手軽です。Anthropic、OpenAI、Gemini、DeepSeek、OpenRouter の API キーや、独自の OpenAI 互換サーバーも使えます。Claude のサブスクリプションではログインできないため、Anthropic の API キーを使ってください。 |

iOS 27 以降ではネイティブサービスで iPhone を操作します。iOS 18 から 26 では XCTest セッションを使うため、iPhone のデベロッパ設定で UI オートメーションを有効にしてください。iPadOS 18 以降の iPad にもインストールできます。

### よくある質問

**Windows からインストールできますか？** はい。Windows 版 Poki Setup は Mac 版と同様にインストール、ペアリング、署名更新に対応しています。先に Apple Devices または iTunes を入れ、iPhone を認識できるようにしてください。[Poki Setup](desktop/README.md) をご覧ください。

**インストール後もパソコンが必要ですか？** 作業は iPhone だけで実行できます。無料の Apple Account では、パソコンの Poki Setup を起動して署名を更新するか、Poki 内で Apple Account にログインして iPhone 自身で更新します。ログインできない場合はパソコンの Poki Setup を使ってください。[起動しておくもの](skills/install-poki/SKILL.md#what-to-keep-running)をご覧ください。

**無料の Apple Account で使えますか？7 日間の制限とは何ですか？** 使えますが、署名の有効期間は 7 日間です。Poki Setup が起動中で、パソコンがスリープせず iPhone に接続できる場合、6 時間ごとに確認し、残り 2 日以下になったアプリの署名を更新します。期限が切れるとアプリを開けなくなるため、Poki は最後の 2 日間に警告します。[有料の開発者アカウントがない場合](skills/install-poki/SKILL.md#no-paid-developer-account)をご覧ください。

**どの iPhone と iOS が必要ですか？** iOS 18 以降の iPhone XS、XR、SE（第 2 世代）以降です。iPadOS 18 以降の iPad にもインストールできます。実機テストは iOS 27 で行っており、別の操作方式を使う iOS 18 から 26 は実機未検証です。[検証結果と既知の制限](docs/verification.md)をご覧ください。

**自分のモデルアカウントが必要ですか？** はい。ChatGPT Plus または Pro でログインするか、Anthropic、OpenAI、Gemini、DeepSeek、OpenRouter の API キー、または独自の OpenAI 互換サーバーを使います。音声会話には音声モデルのキーも必要です。[必要なもの](#必要なもの)をご覧ください。

**中国本土のネットワークなどで更新が表示されない場合は？** 更新の確認先は GitHub です。接続できないネットワークや、403、429 の制限に達した場合は、別のネットワークやプロキシ接続先を試すか、パソコンの Poki Setup で Renew を使ってください。[Poki を更新する](#poki-を更新する)をご覧ください。

**iPhone の内容を変更しますか？操作前に確認しますか？** 実際のアプリでメッセージ送信などの依頼を実行し、画面内容を設定済みのモデルサービスに送ります。支払い、削除、ウォレット内の操作には必ず確認が必要です。メッセージ送信やパスワード入力など、ほかの慎重に扱う操作では、設定 > 承認で確認方法や確認の有無を選べます。[既知の問題](#既知の問題)をご覧ください。

## Poki を更新する

- **iPhone で更新。** 0.4.0 では設定 > 接続 > 署名と更新を開きます。新しいビルドがあればダウンロードとインストールを選べます。ログインを求められた場合は、パソコンからインストールしたため iPhone に Apple Account が保存されていません。インストール時のアカウントでログインするか、パソコンから更新してください。
- **パソコンで更新。** Poki Setup の Renew は選択中のチャンネルの最新ビルドを既存アプリに上書きインストールします。Mac ではエージェントに「iPhone の Poki を更新して」と頼むこともできます。install-poki スキルの更新手順は、先に現在のバージョンと署名の識別情報を確認します。
- 「Finishing the update」で止まったら、アプリスイッチャーで Poki を終了して開き直し、設定でバージョンを確認してください。変わっていなければパソコンの Poki Setup から更新します。更新の修復のために Poki を削除しないでください。会話も消えます。

チャンネルと Alpha から Beta への移行は[リリースチャンネル](docs/release-channels.md)をご覧ください。

## 既知の問題

- Poki は実際の iPhone を操作し、依頼されたメッセージ送信や支払いを実行します。画面内容は設定したモデルサービスに送られます。
- iPhone で Apple Account にログインできない場合は、パソコンの Poki Setup で署名更新とアプリ更新を行ってください。
- 実機で検証済みなのは、中国語表示で縦向きの iPhone のみです。横向きには対応していません。
- このリリースは iOS 27 より前の iPhone 実機や iPad では未検証です。古い機種や小型の iPhone では、立体のクマとホーム画面のアニメーションによって発熱や動作の遅れが生じる可能性があります。低電力モードや「視差効果を減らす」ではクマを静止画で表示します。
- 無料の Apple Account の署名は 7 日間有効です。パソコンの Poki Setup から iPhone に接続できる状態を保つか、期限前に手動で更新してください。
- GitHub のリリース取得で 403 や 429 が返ることがあります。多くはネットワークの共有によるものです。接続先を変えるか、1 時間待って再試行してください。

そのほかの制限とテスト結果は[検証結果と既知の制限](docs/verification.md)をご覧ください。

## タスクを試す

Poki を開き、「明日の天気を調べて、傘が必要か教えて」のように入力するか、ホーム画面のアプリをタップして作業を始めます。Poki は画面上のアプリを操作し、Dynamic Island とロック画面に手順を表示し、設定に従って承認を求めます。

Poki を開かずに呼び出すこともできます。アクションボタンを長押しして話すか、ショートカットや Siri から Talk to Poki または Send Task to Poki を使います。この方法で送ったタスクの結果は通知で届きます。

> **注意：** Poki は実際の iPhone を操作します。メッセージ送信や支払いを頼めば実行します。

## ロードマップ

予定日ではなく方向性を示しています。公開済み機能は [CHANGELOG.md](CHANGELOG.md) に記載しています。

**0.4.0 Beta で公開済み**

- 初期設定後はパソコンなしで動く iPhone アプリ。ロック画面と Dynamic Island での承認。
- 無料の Apple Account を使い、Mac または Windows PC のエージェントや Poki Setup からインストール。
- iOS 27 以降でのネイティブ操作と、Poki 内蔵ブラウザでのウェブタスク。
- 立体のクマがいる新しいホーム画面、音声会話、アクションボタン、会話のアーカイブ、ダークモード。

**進行中**

- 更新用のダウンロード元をより安定したものへ移し、GitHub は予備として維持。
- 複数の更新チャンネルを 1 つに統合。
- インターフェースの対応言語を追加。

**計画中**

- より多くの iPhone、iOS バージョン、画面言語を実機で検証。
- モデルプロバイダーを追加。

## ドキュメント

| 項目 | ドキュメント |
| --- | --- |
| 各バージョンの変更 | [CHANGELOG.md](CHANGELOG.md) |
| エージェントによる iPhone アプリのインストール | [install-poki スキル](skills/install-poki/SKILL.md) |
| Mac と Windows の Poki Setup | [Poki Setup](desktop/README.md) |
| リリースチャンネルと昇格手順 | [リリースチャンネル](docs/release-channels.md) |
| テスト結果、既知の制限、免責事項 | [検証結果](docs/verification.md) |
| ロードマップ | [ロードマップ](#ロードマップ) |

## Star History

<a href="https://www.star-history.com/?repos=JosssphZhou%2Fpoki&type=date&legend=top-left">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=JosssphZhou/poki&type=date&theme=dark&legend=top-left">
    <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=JosssphZhou/poki&type=date&legend=top-left">
    <img alt="Star History chart" src="https://api.star-history.com/chart?repos=JosssphZhou/poki&type=date&legend=top-left">
  </picture>
</a>

## コアコントリビューター

<!-- CORE-CONTRIBUTORS:START -->
<table>
  <tbody>
    <tr>
      <td align="center" valign="top" width="33%"><a href="https://github.com/makirqi-alt"><img src="https://avatars.githubusercontent.com/u/295395617?v=4&size=240" width="120" height="120" alt="makirqi-alt"/><br /><sub><b>makirqi-alt</b></sub></a><br />Poki 最初の issue <a href="https://github.com/JosssphZhou/poki/issues/1">#1</a> を報告。iOS 18.6.2 でスクリーンショットは動き、アクセシビリティとタッチは動かないことを、切り分けてわかりやすく書いてくれました。</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/ZhehanZhang"><img src="https://avatars.githubusercontent.com/u/67270559?v=4&size=240" width="120" height="120" alt="ZhehanZhang"/><br /><sub><b>ZhehanZhang</b></sub></a><br />Poki の偉大な共同創造者。</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/edge369"><img src="https://avatars.githubusercontent.com/u/63720633?v=4&size=240" width="120" height="120" alt="edge369"/><br /><sub><b>edge369</b></sub></a><br /><a href="https://github.com/JosssphZhou/poki/pull/14">#14</a> で Poki をルーター上で動かせるようにし、Mac の電源がオフでも Telegram から iPhone を操作できます。<a href="https://github.com/JosssphZhou/poki/pull/15">#15</a>、<a href="https://github.com/JosssphZhou/poki/pull/17">#17</a>、<a href="https://github.com/JosssphZhou/poki/issues/19">#19</a> が続きました。</td>
    </tr>
    <tr>
      <td align="center" valign="top" width="33%"><a href="https://github.com/mawenhao1028"><img src="https://avatars.githubusercontent.com/u/70818670?v=4&size=240" width="120" height="120" alt="mawenhao1028"/><br /><sub><b>mawenhao1028</b></sub></a><br /><a href="https://github.com/JosssphZhou/poki/issues/6">#6</a> で macOS 27.2 の usbmuxd が iPhone を一覧に出さないことを報告。Poki はそれを明確に伝え、ヘルパーが早く止まる理由も示すようになりました（<a href="https://github.com/JosssphZhou/poki/issues/59">#59</a>）。</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/igc110"><img src="https://avatars.githubusercontent.com/u/241411380?v=4&size=240" width="120" height="120" alt="igc110"/><br /><sub><b>igc110</b></sub></a><br /><a href="https://github.com/JosssphZhou/poki/issues/10">#10</a> で実機 iPhone のタップが遅い原因を突き止め、その後の修正でタップが約 3 分の 1 速くなりました。</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/carrotciallo"><img src="https://avatars.githubusercontent.com/u/69567867?v=4&size=240" width="120" height="120" alt="carrotciallo"/><br /><sub><b>carrotciallo</b></sub></a><br /><a href="https://github.com/JosssphZhou/poki/issues/16">#16</a> で Poki を Linux に移植し、実機 iPhone で USB、LAN、Tailscale 経由の動作を確認しました。README はこの移植版を案内しています。</td>
    </tr>
    <tr>
      <td align="center" valign="top" width="33%"><a href="https://github.com/guangtouge82"><img src="https://avatars.githubusercontent.com/u/269691899?v=4&size=240" width="120" height="120" alt="guangtouge82"/><br /><sub><b>guangtouge82</b></sub></a><br /><a href="https://github.com/JosssphZhou/poki/issues/18">#18</a> で実機 iPhone のタッチ失敗の原因が display service の欠如にあると突き止めました。Poki は何も送信されなかったことを伝え、prepare-device を案内します。</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/Dreaminmaster"><img src="https://avatars.githubusercontent.com/u/189544503?v=4&size=240" width="120" height="120" alt="Dreaminmaster"/><br /><sub><b>Dreaminmaster</b></sub></a><br />壊れたキャッシュ済みルートが無関係な Agent タスクを中断させる問題を修正し（<a href="https://github.com/JosssphZhou/poki/issues/21">#21</a>、<a href="https://github.com/JosssphZhou/poki/pull/22">#22</a>）、続く <a href="https://github.com/JosssphZhou/poki/pull/37">#37</a> で操作後に読み取った画面を Agent が再利用できるようにしました。</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/PeterKingXu1s"><img src="https://avatars.githubusercontent.com/u/89392314?v=4&size=240" width="120" height="120" alt="PeterKingXu1s"/><br /><sub><b>PeterKingXu1s</b></sub></a><br /><a href="https://github.com/JosssphZhou/poki/issues/25">#25</a> で、自然言語の停止リクエストでは iMessage のタスクが止まらないことを報告しました。Poki はタスク中のメッセージに返信し、/stop を案内するようになりました。</td>
    </tr>
    <tr>
      <td align="center" valign="top" width="33%"><a href="https://github.com/ScottH1122"><img src="https://avatars.githubusercontent.com/u/142722955?v=4&size=240" width="120" height="120" alt="ScottH1122"/><br /><sub><b>ScottH1122</b></sub></a><br /><a href="https://github.com/JosssphZhou/poki/issues/27">#27</a> と <a href="https://github.com/JosssphZhou/poki/issues/28">#28</a> で Agent の 2 つの不具合を再現し、その後、キャンセル済みの入力ロック（<a href="https://github.com/JosssphZhou/poki/pull/102">#102</a>）から無効なタッチ座標（<a href="https://github.com/JosssphZhou/poki/pull/136">#136</a>）まで、7 件の修正とテスト修整をマージしました。</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/jiahuipaung"><img src="https://avatars.githubusercontent.com/u/70688286?v=4&size=240" width="120" height="120" alt="jiahuipaung"/><br /><sub><b>jiahuipaung</b></sub></a><br />iPhone の LAN アドレスが変わると RemotePairing 接続が切れる問題（<a href="https://github.com/JosssphZhou/poki/issues/30">#30</a>）を <a href="https://github.com/JosssphZhou/poki/pull/34">#34</a> で修正しました。実機では 768 ミリ秒で再接続できました。</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/Zeno6898"><img src="https://avatars.githubusercontent.com/u/229920081?v=4&size=240" width="120" height="120" alt="Zeno6898"/><br /><sub><b>Zeno6898</b></sub></a><br /><a href="https://github.com/JosssphZhou/poki/issues/35">#35</a> と <a href="https://github.com/JosssphZhou/poki/issues/40">#40</a> でモバイル通信と Windows から iPhone アプリを実機テストし、初回セットアップに Wi-Fi が必要という説明（<a href="https://github.com/JosssphZhou/poki/issues/138">#138</a>）につながりました。<a href="https://github.com/JosssphZhou/poki/issues/162">#162</a> も報告。</td>
    </tr>
    <tr>
      <td align="center" valign="top" width="33%"><a href="https://github.com/scy7796"><img src="https://avatars.githubusercontent.com/u/282529358?v=4&size=240" width="120" height="120" alt="scy7796"/><br /><sub><b>scy7796</b></sub></a><br />Windows ホストから RemotePairing 接続でタップが毎回失敗する問題を <a href="https://github.com/JosssphZhou/poki/pull/39">#39</a> で修正しました。修正後は 5 回中 5 回のタップが成功しました。</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/foshanfm"><img src="https://avatars.githubusercontent.com/u/24779370?v=4&size=240" width="120" height="120" alt="foshanfm"/><br /><sub><b>foshanfm</b></sub></a><br /><a href="https://github.com/JosssphZhou/poki/issues/42">#42</a> で Tailscale 経由の実機 iPhone を使い、保険約款の確認を行いました。この報告が、USB のより分かりやすいエラーと、セッションごとの接続方式の切り替えにつながっています。</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/xiaweiyi713"><img src="https://avatars.githubusercontent.com/u/208608622?v=4&size=240" width="120" height="120" alt="xiaweiyi713"/><br /><sub><b>xiaweiyi713</b></sub></a><br />Poki が実機 iPhone を操作するデモ動画を制作し、新しい訪問者がインストール前に何ができるかを確認できるようにしました。</td>
    </tr>
    <tr>
      <td align="center" valign="top" width="33%"><a href="https://github.com/fucknima"><img src="https://avatars.githubusercontent.com/u/18666223?v=4&size=240" width="120" height="120" alt="f&#42;&#42;&#42;&#42;&#42;&#42;&#42;"/><br /><sub><b>f&#42;&#42;&#42;&#42;&#42;&#42;&#42;</b></sub></a><br /><a href="https://github.com/JosssphZhou/poki/pull/68">#68</a> で OpenCode Go を iPhone アプリのモデルアカウントとして追加。専用の Keychain 認証情報と独立したモデル選択を備えています。</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/owensn951954688"><img src="https://avatars.githubusercontent.com/u/312761798?v=4&size=240" width="120" height="120" alt="owensn951954688"/><br /><sub><b>owensn951954688</b></sub></a><br /><a href="https://github.com/JosssphZhou/poki/issues/69">#69</a> で Runner が約 25 分の待機後にペアリングに失敗する経過を詳しく記録。Setup は Loopback と Pairing の確認を案内するようになりました（<a href="https://github.com/JosssphZhou/poki/issues/70">#70</a>）。</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/kira-ariaki"><img src="https://avatars.githubusercontent.com/u/257352493?v=4&size=240" width="120" height="120" alt="kira-ariaki"/><br /><sub><b>kira-ariaki</b></sub></a><br />バッチ呼び出しがデバイス不明時にクラッシュせず知らせるようにし（<a href="https://github.com/JosssphZhou/poki/pull/74">#74</a>）、POKI_MCP_DEVICE（<a href="https://github.com/JosssphZhou/poki/pull/75">#75</a>）とタスクごとの任意の承認ゲート（<a href="https://github.com/JosssphZhou/poki/pull/77">#77</a>）を追加しました。</td>
    </tr>
    <tr>
      <td align="center" valign="top" width="33%"><a href="https://github.com/Purelite"><img src="https://avatars.githubusercontent.com/u/9334469?v=4&size=240" width="120" height="120" alt="Purelite"/><br /><sub><b>Purelite</b></sub></a><br />ペアリング設定が誤った設定ページへ誘導する問題を修正し、開発者モードと UI オートメーションの手順が正しいページを開くようになりました（<a href="https://github.com/JosssphZhou/poki/pull/137">#137</a>）。</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/heyallencao"><img src="https://avatars.githubusercontent.com/u/258265534?v=4&size=240" width="120" height="120" alt="heyallencao"/><br /><sub><b>heyallencao</b></sub></a><br /><a href="https://github.com/JosssphZhou/poki/pull/139">#139</a> で画面読み取りが呼び出しの期限を超える問題を修正し、常に遅い Runner 応答に対する回帰テストも追加しました。</td>
    </tr>
  </tbody>
</table>
<!-- CORE-CONTRIBUTORS:END -->

## 特別な貢献者

<table>
  <tbody>
    <tr>
      <td align="center" valign="top" width="33%"><a href="https://github.com/yulunRyanw"><img src="https://avatars.githubusercontent.com/u/216360668?v=4&size=240" width="120" height="120" alt="yulunRyanw"/><br /><sub><b>yulunRyanw</b></sub></a><br />0.4.0 の刷新に向け、チャット、ライブアクティビティ、設定、初回起動の一式の画面デザインを提供しました（<a href="https://github.com/JosssphZhou/poki/pull/250">#250</a>, <a href="https://github.com/JosssphZhou/poki/pull/256">#256</a>, <a href="https://github.com/JosssphZhou/poki/pull/268">#268</a>）。新しいインターフェースの方向性に反映されています。</td>
    </tr>
  </tbody>
</table>

## スペシャルサンクス

Issue や Pull Request を寄せてくださった皆さまに感謝いたします。皆さまのご報告と修正が Poki をより良くしています。

<!-- THANKS-WALL:START -->
<table>
  <tbody>
    <tr>
      <td align="center" valign="top" width="20%"><a href="https://github.com/ZhehanZhang"><img src="https://avatars.githubusercontent.com/u/67270559?v=4&size=160" width="80" height="80" alt="ZhehanZhang"/><br /><sub><b>ZhehanZhang</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/carrotciallo"><img src="https://avatars.githubusercontent.com/u/69567867?v=4&size=160" width="80" height="80" alt="carrotciallo"/><br /><sub><b>carrotciallo</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/Dreaminmaster"><img src="https://avatars.githubusercontent.com/u/189544503?v=4&size=160" width="80" height="80" alt="Dreaminmaster"/><br /><sub><b>Dreaminmaster</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/edge369"><img src="https://avatars.githubusercontent.com/u/63720633?v=4&size=160" width="80" height="80" alt="edge369"/><br /><sub><b>edge369</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/foshanfm"><img src="https://avatars.githubusercontent.com/u/24779370?v=4&size=160" width="80" height="80" alt="foshanfm"/><br /><sub><b>foshanfm</b></sub></a></td>
    </tr>
    <tr>
      <td align="center" valign="top" width="20%"><a href="https://github.com/fucknima"><img src="https://avatars.githubusercontent.com/u/18666223?v=4&size=160" width="80" height="80" alt="f&#42;&#42;&#42;&#42;&#42;&#42;&#42;"/><br /><sub><b>f&#42;&#42;&#42;&#42;&#42;&#42;&#42;</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/guangtouge82"><img src="https://avatars.githubusercontent.com/u/269691899?v=4&size=160" width="80" height="80" alt="guangtouge82"/><br /><sub><b>guangtouge82</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/heyallencao"><img src="https://avatars.githubusercontent.com/u/258265534?v=4&size=160" width="80" height="80" alt="heyallencao"/><br /><sub><b>heyallencao</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/htx996"><img src="https://avatars.githubusercontent.com/u/95217139?v=4&size=160" width="80" height="80" alt="htx996"/><br /><sub><b>htx996</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/igc110"><img src="https://avatars.githubusercontent.com/u/241411380?v=4&size=160" width="80" height="80" alt="igc110"/><br /><sub><b>igc110</b></sub></a></td>
    </tr>
    <tr>
      <td align="center" valign="top" width="20%"><a href="https://github.com/iTry"><img src="https://avatars.githubusercontent.com/u/1381960?v=4&size=160" width="80" height="80" alt="iTry"/><br /><sub><b>iTry</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/jiahuipaung"><img src="https://avatars.githubusercontent.com/u/70688286?v=4&size=160" width="80" height="80" alt="jiahuipaung"/><br /><sub><b>jiahuipaung</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/kilingzhang"><img src="https://avatars.githubusercontent.com/u/17439300?v=4&size=160" width="80" height="80" alt="kilingzhang"/><br /><sub><b>kilingzhang</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/kira-ariaki"><img src="https://avatars.githubusercontent.com/u/257352493?v=4&size=160" width="80" height="80" alt="kira-ariaki"/><br /><sub><b>kira-ariaki</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/lunar-me"><img src="https://avatars.githubusercontent.com/u/275556969?v=4&size=160" width="80" height="80" alt="lunar-me"/><br /><sub><b>lunar-me</b></sub></a></td>
    </tr>
    <tr>
      <td align="center" valign="top" width="20%"><a href="https://github.com/makirqi-alt"><img src="https://avatars.githubusercontent.com/u/295395617?v=4&size=160" width="80" height="80" alt="makirqi-alt"/><br /><sub><b>makirqi-alt</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/mawenhao1028"><img src="https://avatars.githubusercontent.com/u/70818670?v=4&size=160" width="80" height="80" alt="mawenhao1028"/><br /><sub><b>mawenhao1028</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/oasis979559-alt"><img src="https://avatars.githubusercontent.com/u/295108220?v=4&size=160" width="80" height="80" alt="oasis979559-alt"/><br /><sub><b>oasis979559-alt</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/owensn951954688"><img src="https://avatars.githubusercontent.com/u/312761798?v=4&size=160" width="80" height="80" alt="owensn951954688"/><br /><sub><b>owensn951954688</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/PeterKingXu1s"><img src="https://avatars.githubusercontent.com/u/89392314?v=4&size=160" width="80" height="80" alt="PeterKingXu1s"/><br /><sub><b>PeterKingXu1s</b></sub></a></td>
    </tr>
    <tr>
      <td align="center" valign="top" width="20%"><a href="https://github.com/Purelite"><img src="https://avatars.githubusercontent.com/u/9334469?v=4&size=160" width="80" height="80" alt="Purelite"/><br /><sub><b>Purelite</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/ScottH1122"><img src="https://avatars.githubusercontent.com/u/142722955?v=4&size=160" width="80" height="80" alt="ScottH1122"/><br /><sub><b>ScottH1122</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/scy7796"><img src="https://avatars.githubusercontent.com/u/282529358?v=4&size=160" width="80" height="80" alt="scy7796"/><br /><sub><b>scy7796</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/wanghao-SunSky"><img src="https://avatars.githubusercontent.com/u/73684879?v=4&size=160" width="80" height="80" alt="wanghao-SunSky"/><br /><sub><b>wanghao-SunSky</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/windywendyday"><img src="https://avatars.githubusercontent.com/u/65647922?v=4&size=160" width="80" height="80" alt="windywendyday"/><br /><sub><b>windywendyday</b></sub></a></td>
    </tr>
    <tr>
      <td align="center" valign="top" width="20%"><a href="https://github.com/xiaweiyi713"><img src="https://avatars.githubusercontent.com/u/208608622?v=4&size=160" width="80" height="80" alt="xiaweiyi713"/><br /><sub><b>xiaweiyi713</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/yulunRyanw"><img src="https://avatars.githubusercontent.com/u/216360668?v=4&size=160" width="80" height="80" alt="yulunRyanw"/><br /><sub><b>yulunRyanw</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/zcyoung2000"><img src="https://avatars.githubusercontent.com/u/62181891?v=4&size=160" width="80" height="80" alt="zcyoung2000"/><br /><sub><b>zcyoung2000</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/Zeno6898"><img src="https://avatars.githubusercontent.com/u/229920081?v=4&size=160" width="80" height="80" alt="Zeno6898"/><br /><sub><b>Zeno6898</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/zqy5608"><img src="https://avatars.githubusercontent.com/u/14949471?v=4&size=160" width="80" height="80" alt="zqy5608"/><br /><sub><b>zqy5608</b></sub></a></td>
    </tr>
  </tbody>
</table>
<!-- THANKS-WALL:END -->

## その他のツール

[Poki MCP](docs/poki-mcp.md) はパソコンのエージェントを iPhone や iOS シミュレータに接続する従来のツールで、現在は更新を停止しています。

[Poki Agent](docs/poki-mcp.md#try-a-task-with-poki-agent) は iMessage と Telegram に対応したターミナルのエージェントです。設定と使い方はリンク先のガイドにあります。

## 免責事項

Poki は独立したオープンソースプロジェクトです。Apple、OpenAI、および Poki が操作するアプリやウェブサイトの開発元とは提携関係になく、それらの承認も受けていません。iPhone は Apple Inc. の商標です。

サードパーティのアプリやウェブサイトの自動操作は、それらの利用規約に違反する可能性があります。特定のサービスで Poki を使うかどうかは、ご自身で判断してください。お使いのデバイスとアカウント上で Poki が行うこと（送信したメッセージ、加えた変更、その結果生じたアカウントの制限を含む）については、ご自身の責任となります。

Poki は AGPL-3.0 ライセンスの定めるとおり、無保証かつ「現状のまま」提供されます。

## ライセンス

Poki のコードは [AGPL-3.0-only ライセンス](LICENSE)のもとでオープンソースとして公開されています。

Poki のクマ、アプリアイコン、その他の Poki のアートワークはこのライセンスの対象外です。Poki を紹介するためにスクリーンショットを使うことはできます。フォークには独自の名前とアートワークが必要です。詳しくは [BRAND.md](BRAND.md) をご覧ください。

Copyright (c) 2026 Joseph Zhou (周瑟夫) and contributors. オープンソースの依存関係とサードパーティの素材には、それぞれのライセンスが適用されます。[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) を参照してください。コントリビュートについては [CONTRIBUTING.md](CONTRIBUTING.md) をご覧ください。

## 謝辞

Poki が使うオープンソースの依存関係と素材は[サードパーティの表記](THIRD_PARTY_NOTICES.md)をご覧ください。
