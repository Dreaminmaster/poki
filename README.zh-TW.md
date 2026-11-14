<p align="center">
  <img src="docs/images/poki-icon.png" width="72" height="72" alt="Poki icon">
</p>

<h1 align="center">Poki 用你的 iPhone，就像你自己在用</h1>

<p align="center">
  <img src="docs/images/poki-home.gif" width="720" alt="Poki 官網首頁動畫">
</p>

<p align="center">
  <a href="README.md">English</a> | <a href="README.zh-CN.md">简体中文</a> | 繁體中文 | <a href="README.ja.md">日本語</a> | <a href="README.ko.md">한국어</a> | <a href="README.es.md">Español</a><br>
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

Poki 是能操作你 iPhone 的應用程式。它會讀取螢幕，在真實應用程式中點選、輸入和滾動。你可以選擇它如何徵求許可；付款、刪除和錢包中的操作始終需要確認。

**Poki App** 直接在 iPhone 上執行。你在對話裡交代任務，它就到其他應用程式中執行。透過 Mac 或 Windows 電腦安裝一次後，執行任務不再需要電腦。

每個版本的變化見 [CHANGELOG.md](CHANGELOG.md)。

## 在 iPhone 上安裝 Poki

首次安裝需要一臺 Mac 或 Windows 電腦。

- **Mac 使用者**可以讓代理程式安裝 Poki，也可以下載 macOS 版 Poki Setup，按視窗提示操作。
- **Windows 使用者**可以下載 Windows 版 Poki Setup，按視窗提示操作。請先安裝 Apple Devices 或 iTunes，讓電腦能透過 USB 辨識 iPhone。代理程式也可以呼叫 Poki Setup 內建的命令列工具。
- **安裝後**，Poki 在 iPhone 上獨立執行任務。免費 Apple 帳號的簽署有效期為 7 天，電腦上的 Poki Setup 保持執行時可以重新簽署。詳見[常見問題](#常見問題)。

### 讓代理程式安裝（推薦）

把下面這段發給 Claude Code、Codex 等代理程式：

```text
從 https://github.com/JosssphZhou/poki 把 Poki 安裝到我的 iPhone 上
```

代理程式會按 [install-poki 技能](skills/install-poki/SKILL.md)執行 `bin/install-iphone.mjs`，完成能自動處理的步驟。你只需處理 iOS 要求本人完成的操作：在 Mac 上的 Poki Setup 視窗輸入 Apple 帳號，在 iPhone 上點「信任」、開啟開發者模式、信任開發者，然後開啟 Poki。首次開啟會請求開啟自動化模式，點「繼續」並輸入 iPhone 密碼即可。如果取消，重新開啟 Poki 後會再次詢問。每一步需要你操作時，代理程式都會說明。免費 Apple 帳號也能用。

安裝器預設使用 Alpha 通道，你也可以讓代理程式改用 Beta 等其他通道。組建先進入 Alpha，經過更多測試後，同一組建再進入 Beta。

沒有 Node.js 24，或使用 Windows？裝好 Poki Setup 後，同一段提示也能用，代理程式會呼叫其內建命令列工具。Poki Setup 選單也能複製安裝提示，Mac 上位於 Poki > Copy Prompt for Your Agent，Windows 上位於 Settings > Use an agent。

如果安裝器讀取 GitHub 發布資訊時遇到 403 或 429，通常是同一網路共用的匿名請求額度已耗盡。可以換網路或代理節點重試，也可以等一小時。

### 使用 Poki Setup 安裝

想自己點選安裝？從 [Alpha 發布頁](https://github.com/JosssphZhou/poki/releases/tag/app-alpha-latest)下載 macOS 版 Poki Setup（`.dmg`）或 Windows 版（`.exe`，由 [ZhehanZhang](https://github.com/ZhehanZhang) 貢獻），按視窗提示操作。Beta 發布頁提供相同的 Poki Setup 檔案。在設定裡選擇通道前，Poki Setup 會安裝最新 Stable 版；沒有 Stable 時則安裝 Beta 版。詳細步驟見 [Poki Setup](desktop/README.md)。

### 需要準備什麼

| 項目 | 要求 |
| --- | --- |
| iPhone | iOS 18 或更高版本，即 iPhone XS、XR、SE（第 2 代）或更新機型。Poki 已在執行 iOS 27 的 iPhone 真機上測試。 |
| 電腦 | macOS 14 或更高版本的 Mac，或已安裝 Apple Devices 或 iTunes 的 Windows 電腦（x64）。在 Mac 上透過指令碼讓代理程式安裝還需要 Node.js 24 或更高版本。 |
| 資料線與帳號 | USB 資料線和 Apple 帳號。免費帳號簽署有效期為 7 天，Poki Setup 可以重新簽署。 |
| 連線 | iPhone 上需要能將 10.7.0.1 連回本機的 VPN 應用程式。可用 App Store 上免費的 LocalDevVPN，也可按 Poki 的說明設定 Karing 或 Shadowrocket。 |
| 模型帳號 | 需要自備。用 ChatGPT Plus 或 Pro 方案登入最方便，也可以填寫 Anthropic、OpenAI、Gemini、DeepSeek 或 OpenRouter 的 API 金鑰，或接入自己的 OpenAI 相容服務。Claude 訂閱不能直接登入，請使用 Anthropic API 金鑰。 |

iOS 27 及以上透過原生服務控制 iPhone。iOS 18 至 26 使用 XCTest 工作階段，需要在 iPhone 的開發者設定裡開啟 UI 自動化。應用程式也可安裝到 iPadOS 18 或更高版本的 iPad。

### 常見問題

**Windows 能安裝嗎？** 可以。Windows 版 Poki Setup 和 Mac 版一樣支援安裝、配對和重新簽署。先安裝 Apple Devices 或 iTunes，讓電腦能辨識 iPhone。詳見 [Poki Setup](desktop/README.md)。

**安裝後還需要電腦嗎？** 執行任務不需要，Poki 在 iPhone 上獨立執行。免費 Apple 帳號需要重新簽署，可保持電腦上的 Poki Setup 執行，也可以在 Poki 內登入 Apple 帳號，讓 iPhone 自己重新簽署。若登入失敗，請改用電腦上的 Poki Setup。詳見[哪些需要保持執行](skills/install-poki/SKILL.md#what-to-keep-running)。

**免費 Apple 帳號能用嗎？7 天是什麼意思？** 能用，但 Apple 為免費帳號簽發的應用程式簽署只有 7 天有效期。Poki Setup 保持執行、電腦未睡眠且能連線 iPhone 時，會每 6 小時檢查並為剩餘有效期不超過 2 天的應用程式重新簽署。未重新簽署的應用程式到期後無法開啟，Poki 會在最後 2 天提醒。詳見[沒有付費開發者帳號](skills/install-poki/SKILL.md#no-paid-developer-account)。

**需要哪款 iPhone 和哪個 iOS 版本？** iOS 18 或更高版本，即 iPhone XS、XR、SE（第 2 代）或更新機型，也支援安裝到 iPadOS 18 或更高版本的 iPad。目前真機測試使用 iOS 27，iOS 18 至 26 的控制方式不同，尚未在真機驗證。詳見[驗證記錄與已知限制](docs/verification.md)。

**需要自己的模型帳號嗎？** 需要。可用 ChatGPT Plus 或 Pro 登入，填寫 Anthropic、OpenAI、Gemini、DeepSeek 或 OpenRouter 的 API 金鑰，或接入自己的 OpenAI 相容服務。語音對話還需要語音模型金鑰。詳見[需要準備什麼](#需要準備什麼)。

**看不到更新，例如在中國大陸的網路上，怎麼辦？** Poki 從 GitHub 檢查更新，部分網路無法存取，或遇到 403、429 請求限制。可換網路或代理節點，也可以在電腦上的 Poki Setup 中使用 Renew 更新。詳見[更新 Poki](#更新-poki)。

**Poki 會修改手機裡的內容嗎？操作前會詢問嗎？** Poki 會在真實應用程式裡執行你的要求，包括傳送訊息，螢幕內容會傳送到你設定的模型服務。付款、刪除和錢包中的操作始終需要確認。其他敏感步驟，例如傳送訊息或輸入密碼，可以在設定 > 核准中選擇詢問方式，也可以選擇不詢問。詳見[已知問題](#已知問題)。

## 更新 Poki

- **在 iPhone 上更新。** 0.4.0 中開啟設定 > 連線 > 簽署與更新。有新組建時，頁面會提供下載和安裝。如果要求先登入，說明 Poki 從電腦安裝，手機上還沒有你的 Apple 帳號。請使用安裝時的帳號登入，或改用電腦更新。
- **從電腦更新。** Poki Setup 中的 Renew 會將所選通道的最新組建安裝到現有應用程式上。Mac 使用者也可以告訴代理程式「更新我 iPhone 上的 Poki」。install-poki 技能有獨立的更新流程，會先核對已安裝版本和簽署身分。
- 如果更新停在「正在完成更新」，請在應用程式切換器中向上滑動關閉 Poki，再重新開啟並檢視設定中的版本。版本未變化時，請用電腦上的 Poki Setup 更新。不要為了修復更新而刪除 Poki，刪除應用程式會一併刪除對話。

發布通道以及組建從 Alpha 進入 Beta 的方式見[發布通道](docs/release-channels.md)。

## 已知問題

- Poki 操作的是真實 iPhone，會按要求傳送訊息或付款。螢幕內容會傳送到你設定的模型服務。
- 如果無法在 iPhone 上登入 Apple 帳號，請用電腦上的 Poki Setup 重新簽署和更新。
- 真機支援目前只在中文介面、直向的 iPhone 上驗證過，不支援橫向。
- 本版本尚未在低於 iOS 27 的 iPhone 真機或 iPad 上測試。較老或較小的 iPhone 執行立體小熊和首頁動畫時可能更熱、更慢。低耗電模式或減少動態效果會改為顯示靜態小熊。
- 免費 Apple 帳號的簽署有效期為 7 天。請確保電腦上的 Poki Setup 能連線 iPhone，或在到期前手動重新簽署。
- 從 GitHub 讀取發布資訊可能遇到 403 或 429，通常是多人共用網路所致。可換網路或代理節點重試，也可以等一小時。

更多限制和測試結果見[驗證記錄與已知限制](docs/verification.md)。

## 試跑一個任務

開啟 Poki，在輸入框裡寫下任務，例如「查一下明天的天氣，告訴我需不需要帶傘」，也可以點首頁的應用程式來發起任務。Poki 會操作螢幕上的應用程式，在動態島和鎖定畫面上顯示每一步，並按你的設定徵求許可。

你也可以不用開啟 Poki：長按動作按鈕與它交談，或透過捷徑和 Siri 呼叫 Talk to Poki、Send Task to Poki。這樣傳送的任務會透過通知回覆。

> **注意：** Poki 控制的是真實 iPhone。你讓它發訊息或付款，它就會執行。

## 路線圖

這裡只列方向，不承諾日期。已發布功能見 [CHANGELOG.md](CHANGELOG.md)。

**0.4.0 Beta 已發布**

- iPhone App 在設定完成後無需電腦即可執行任務，鎖定畫面和動態島支援核准。
- 使用免費 Apple 帳號，透過 Mac 或 Windows 上的代理程式或 Poki Setup 安裝。
- iOS 27 及以上的原生控制，以及 Poki 內建瀏覽器中的網頁任務。
- 立體小熊新首頁、語音對話、動作按鈕、對話封存和深色模式。

**進行中**

- 將更新遷到更穩定的下載源，GitHub 保留為備用。
- 將多個更新通道合成一個。
- 更多介面語言。

**規劃中**

- 在真機上驗證更多 iPhone、iOS 版本和螢幕語言。
- 支援更多模型提供商。

## 文件

| 主題 | 文件 |
| --- | --- |
| 各版本變化 | [CHANGELOG.md](CHANGELOG.md) |
| 讓代理程式安裝 iPhone App | [install-poki 技能](skills/install-poki/SKILL.md) |
| Mac 和 Windows 上的 Poki Setup | [Poki Setup](desktop/README.md) |
| 發布通道和版本晉級方式 | [發布通道](docs/release-channels.md) |
| 測試結果、已知限制和免責宣告 | [驗證與限制](docs/verification.md) |
| 路線圖 | [路線圖](#路線圖) |

## Star History

<a href="https://www.star-history.com/?repos=JosssphZhou%2Fpoki&type=date&legend=top-left">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=JosssphZhou/poki&type=date&theme=dark&legend=top-left">
    <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=JosssphZhou/poki&type=date&legend=top-left">
    <img alt="Star History chart" src="https://api.star-history.com/chart?repos=JosssphZhou/poki&type=date&legend=top-left">
  </picture>
</a>

## 核心貢獻者

<!-- CORE-CONTRIBUTORS:START -->
<table>
  <tbody>
    <tr>
      <td align="center" valign="top" width="33%"><a href="https://github.com/makirqi-alt"><img src="https://avatars.githubusercontent.com/u/295395617?v=4&size=240" width="120" height="120" alt="makirqi-alt"/><br /><sub><b>makirqi-alt</b></sub></a><br />提交了 Poki 的第一個問題 <a href="https://github.com/JosssphZhou/poki/issues/1">#1</a>：在 iOS 18.6.2 上截圖正常，輔助功能和觸控不可用，哪些能用哪些不能寫得很清楚。</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/ZhehanZhang"><img src="https://avatars.githubusercontent.com/u/67270559?v=4&size=240" width="120" height="120" alt="ZhehanZhang"/><br /><sub><b>ZhehanZhang</b></sub></a><br />Poki 偉大的共同創造者。</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/edge369"><img src="https://avatars.githubusercontent.com/u/63720633?v=4&size=240" width="120" height="120" alt="edge369"/><br /><sub><b>edge369</b></sub></a><br />在 <a href="https://github.com/JosssphZhou/poki/pull/14">#14</a> 讓 Poki 能在路由器上執行，Mac 關機時也能透過 Telegram 操作 iPhone；<a href="https://github.com/JosssphZhou/poki/pull/15">#15</a>、<a href="https://github.com/JosssphZhou/poki/pull/17">#17</a> 和 <a href="https://github.com/JosssphZhou/poki/issues/19">#19</a> 隨後跟進。</td>
    </tr>
    <tr>
      <td align="center" valign="top" width="33%"><a href="https://github.com/mawenhao1028"><img src="https://avatars.githubusercontent.com/u/70818670?v=4&size=240" width="120" height="120" alt="mawenhao1028"/><br /><sub><b>mawenhao1028</b></sub></a><br />在 <a href="https://github.com/JosssphZhou/poki/issues/6">#6</a> 中回報 macOS 27.2 上 usbmuxd 列不出任何 iPhone；Poki 現在會直接說明這一點，以及輔助程式為何提前停止（<a href="https://github.com/JosssphZhou/poki/issues/59">#59</a>）。</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/igc110"><img src="https://avatars.githubusercontent.com/u/241411380?v=4&size=240" width="120" height="120" alt="igc110"/><br /><sub><b>igc110</b></sub></a><br />在 <a href="https://github.com/JosssphZhou/poki/issues/10">#10</a> 查明實體 iPhone 點按慢的原因，隨後的修正讓點按快了約三分之一。</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/carrotciallo"><img src="https://avatars.githubusercontent.com/u/69567867?v=4&size=240" width="120" height="120" alt="carrotciallo"/><br /><sub><b>carrotciallo</b></sub></a><br />在 <a href="https://github.com/JosssphZhou/poki/issues/16">#16</a> 把 Poki 移植到 Linux，並在實體 iPhone 上透過 USB、區域網路和 Tailscale 驗證；README 現已指向該移植版。</td>
    </tr>
    <tr>
      <td align="center" valign="top" width="33%"><a href="https://github.com/guangtouge82"><img src="https://avatars.githubusercontent.com/u/269691899?v=4&size=240" width="120" height="120" alt="guangtouge82"/><br /><sub><b>guangtouge82</b></sub></a><br />在 <a href="https://github.com/JosssphZhou/poki/issues/18">#18</a> 把實體 iPhone 觸控失敗追查到缺少 display service；現在 Poki 會說明沒有送出任何輸入，並指向 prepare-device。</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/Dreaminmaster"><img src="https://avatars.githubusercontent.com/u/189544503?v=4&size=240" width="120" height="120" alt="Dreaminmaster"/><br /><sub><b>Dreaminmaster</b></sub></a><br />修正了損壞的路由快取中斷無關 Agent 任務的問題（<a href="https://github.com/JosssphZhou/poki/issues/21">#21</a>、<a href="https://github.com/JosssphZhou/poki/pull/22">#22</a>），隨後在 <a href="https://github.com/JosssphZhou/poki/pull/37">#37</a> 讓 Agent 重用操作後已讀到的畫面。</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/PeterKingXu1s"><img src="https://avatars.githubusercontent.com/u/89392314?v=4&size=240" width="120" height="120" alt="PeterKingXu1s"/><br /><sub><b>PeterKingXu1s</b></sub></a><br />在 <a href="https://github.com/JosssphZhou/poki/issues/25">#25</a> 回報 iMessage 任務不會被自然語言的停止請求打斷；現在 Poki 會回覆任務途中的訊息，並提示使用 /stop。</td>
    </tr>
    <tr>
      <td align="center" valign="top" width="33%"><a href="https://github.com/ScottH1122"><img src="https://avatars.githubusercontent.com/u/142722955?v=4&size=240" width="120" height="120" alt="ScottH1122"/><br /><sub><b>ScottH1122</b></sub></a><br />在 <a href="https://github.com/JosssphZhou/poki/issues/27">#27</a> 和 <a href="https://github.com/JosssphZhou/poki/issues/28">#28</a> 中重現了兩個 Agent 缺陷，隨後合併了七項修正和測試修整，從已取消的輸入鎖（<a href="https://github.com/JosssphZhou/poki/pull/102">#102</a>）到無效的觸控座標（<a href="https://github.com/JosssphZhou/poki/pull/136">#136</a>）。</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/jiahuipaung"><img src="https://avatars.githubusercontent.com/u/70688286?v=4&size=240" width="120" height="120" alt="jiahuipaung"/><br /><sub><b>jiahuipaung</b></sub></a><br />在 <a href="https://github.com/JosssphZhou/poki/pull/34">#34</a> 修正了 iPhone 區域網路位址變更後 RemotePairing 連線失效的問題（<a href="https://github.com/JosssphZhou/poki/issues/30">#30</a>）；實體 iPhone 重新連線只花了 768 毫秒。</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/Zeno6898"><img src="https://avatars.githubusercontent.com/u/229920081?v=4&size=240" width="120" height="120" alt="Zeno6898"/><br /><sub><b>Zeno6898</b></sub></a><br />在 <a href="https://github.com/JosssphZhou/poki/issues/35">#35</a> 和 <a href="https://github.com/JosssphZhou/poki/issues/40">#40</a> 中實地測試了 iPhone 應用，涵蓋行動網路和 Windows，促成了首次設定需要 Wi-Fi 的說明（<a href="https://github.com/JosssphZhou/poki/issues/138">#138</a>）；還回報了 <a href="https://github.com/JosssphZhou/poki/issues/162">#162</a>。</td>
    </tr>
    <tr>
      <td align="center" valign="top" width="33%"><a href="https://github.com/scy7796"><img src="https://avatars.githubusercontent.com/u/282529358?v=4&size=240" width="120" height="120" alt="scy7796"/><br /><sub><b>scy7796</b></sub></a><br />在 <a href="https://github.com/JosssphZhou/poki/pull/39">#39</a> 修正了 Windows 主機經 RemotePairing 連線時每次點按都失敗的問題；修正後 5 次點按全部成功。</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/foshanfm"><img src="https://avatars.githubusercontent.com/u/24779370?v=4&size=240" width="120" height="120" alt="foshanfm"/><br /><sub><b>foshanfm</b></sub></a><br />在 <a href="https://github.com/JosssphZhou/poki/issues/42">#42</a> 透過 Tailscale 在實體 iPhone 上做了一次保險條款核對；這份報告推動了更清楚的 USB 錯誤訊息，以及依工作階段切換連線方式。</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/xiaweiyi713"><img src="https://avatars.githubusercontent.com/u/208608622?v=4&size=240" width="120" height="120" alt="xiaweiyi713"/><br /><sub><b>xiaweiyi713</b></sub></a><br />錄製了 Poki 操作實體 iPhone 的示範影片，讓新訪客在安裝之前就能看到它能做什麼。</td>
    </tr>
    <tr>
      <td align="center" valign="top" width="33%"><a href="https://github.com/fucknima"><img src="https://avatars.githubusercontent.com/u/18666223?v=4&size=240" width="120" height="120" alt="f&#42;&#42;&#42;&#42;&#42;&#42;&#42;"/><br /><sub><b>f&#42;&#42;&#42;&#42;&#42;&#42;&#42;</b></sub></a><br />在 <a href="https://github.com/JosssphZhou/poki/pull/68">#68</a> 中把 OpenCode Go 加為 iPhone 應用的模型帳號，附獨立的鑰匙圈憑證和獨立的模型選擇。</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/owensn951954688"><img src="https://avatars.githubusercontent.com/u/312761798?v=4&size=240" width="120" height="120" alt="owensn951954688"/><br /><sub><b>owensn951954688</b></sub></a><br />在 <a href="https://github.com/JosssphZhou/poki/issues/69">#69</a> 中提供了 Runner 閒置約 25 分鐘後配對失敗的完整時間線；設定頁現在會指向回環和配對檢查（<a href="https://github.com/JosssphZhou/poki/issues/70">#70</a>）。</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/kira-ariaki"><img src="https://avatars.githubusercontent.com/u/257352493?v=4&size=240" width="120" height="120" alt="kira-ariaki"/><br /><sub><b>kira-ariaki</b></sub></a><br />讓批次呼叫在裝置不明確時給出提示而不是當機（<a href="https://github.com/JosssphZhou/poki/pull/74">#74</a>），並新增 POKI_MCP_DEVICE（<a href="https://github.com/JosssphZhou/poki/pull/75">#75</a>）和可選的逐任務核准（<a href="https://github.com/JosssphZhou/poki/pull/77">#77</a>）。</td>
    </tr>
    <tr>
      <td align="center" valign="top" width="33%"><a href="https://github.com/Purelite"><img src="https://avatars.githubusercontent.com/u/9334469?v=4&size=240" width="120" height="120" alt="Purelite"/><br /><sub><b>Purelite</b></sub></a><br />修正配對設定把人帶到錯誤設定頁面的問題，開發者模式和 UI 自動化步驟現在會開啟正確的頁面（<a href="https://github.com/JosssphZhou/poki/pull/137">#137</a>）。</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/heyallencao"><img src="https://avatars.githubusercontent.com/u/258265534?v=4&size=240" width="120" height="120" alt="heyallencao"/><br /><sub><b>heyallencao</b></sub></a><br />在 <a href="https://github.com/JosssphZhou/poki/pull/139">#139</a> 中修正讀取畫面超過呼叫期限的問題，並為持續變慢的 Runner 回應補上回歸測試。</td>
    </tr>
  </tbody>
</table>
<!-- CORE-CONTRIBUTORS:END -->

## 特別貢獻者

<table>
  <tbody>
    <tr>
      <td align="center" valign="top" width="33%"><a href="https://github.com/yulunRyanw"><img src="https://avatars.githubusercontent.com/u/216360668?v=4&size=240" width="120" height="120" alt="yulunRyanw"/><br /><sub><b>yulunRyanw</b></sub></a><br />為 0.4.0 改版提供完整的介面設計，涵蓋對話、即時動態、設定與首次使用流程（<a href="https://github.com/JosssphZhou/poki/pull/250">#250</a>, <a href="https://github.com/JosssphZhou/poki/pull/256">#256</a>, <a href="https://github.com/JosssphZhou/poki/pull/268">#268</a>），為新介面提供了方向。</td>
    </tr>
  </tbody>
</table>

## 感謝牆

感謝每一位提交過 Issue 或 Pull Request 的朋友，你們的回報與修正讓 Poki 變得更好。

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

## 其他工具

[Poki MCP](docs/poki-mcp.md) 將電腦上的代理程式連接到 iPhone 或 iOS 模擬器，這項早期工具已停止更新。

[Poki Agent](docs/poki-mcp.md#try-a-task-with-poki-agent) 是支援 iMessage 和 Telegram 的終端機代理程式，安裝與使用方式請見連結中的指南。

## 免責聲明

Poki 是獨立的開源專案，與 Apple、OpenAI 以及它所操作的任何 App 或網站的開發者都沒有關聯，也未獲得其背書。iPhone 是 Apple Inc. 的商標。

自動化操作第三方 App 和網站可能違反其服務條款。是否在特定服務上使用 Poki，請自行判斷。Poki 在你的裝置和帳號上做的事由你負責，包括它發送的訊息、做出的變更，以及因此造成的任何帳號限制。

Poki 依「現狀」提供，不附帶任何擔保，詳見 AGPL-3.0 授權條款。

## 授權條款

Poki 的程式碼以 [AGPL-3.0-only 授權條款](LICENSE)開源。

Poki 小熊、App 圖示和 Poki 的其他美術作品不在此授權範圍內。你可以用截圖介紹 Poki；分支版本需要使用自己的名稱和美術。詳見 [BRAND.md](BRAND.md)。

Copyright (c) 2026 Joseph Zhou (周瑟夫) and contributors. 開源相依套件和第三方素材保留各自的授權條款，詳見 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。想參與貢獻，請見 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 致謝

Poki 使用的開源相依套件與素材請見[第三方聲明](THIRD_PARTY_NOTICES.md)。
