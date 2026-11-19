# Poki iPhone 使用指南

[English](iphone-guide.md) | [简体中文](iphone-guide.zh-CN.md) | 繁體中文 | [日本語](iphone-guide.ja.md) | [한국어](iphone-guide.ko.md) | [Español](iphone-guide.es.md)

本指南涵蓋 Poki iPhone 應用程式的完整系統需求、安裝細節、更新方式、常見問題、已知限制與任務範例。

各版本變更請見 [CHANGELOG.md](../CHANGELOG.md)。

## 需要準備什麼

| 項目 | 要求 |
| --- | --- |
| iPhone | iOS 18 或更高版本，即 iPhone XS、XR、SE（第 2 代）或更新機型。Poki 已在執行 iOS 27 的 iPhone 真機上測試。 |
| 電腦 | macOS 14 或更高版本的 Mac，或已安裝 Apple Devices 或 iTunes 的 Windows 電腦（x64）。在 Mac 上透過代理程式安裝還需要 Node.js 24 或更高版本。 |
| 資料線與帳號 | USB 資料線和 Apple 帳號。免費帳號簽署有效期為 7 天，Poki Setup 可以為你重新簽署。 |
| 連線 | iPhone 上需要能將 `10.7.0.1` 路由回本機的 VPN 應用程式。可用 App Store 上免費的 LocalDevVPN，也可按 Poki 的說明設定 Karing 或 Shadowrocket。 |
| 模型帳號 | 需要自備。用 ChatGPT Plus 或 Pro 方案登入最方便，也可以填寫 Anthropic、OpenAI、Gemini、DeepSeek、OpenRouter 或 OpenCode Go 的 API 金鑰，或接入自己的 OpenAI 相容服務。Claude 訂閱不能直接登入，請使用 Anthropic API 金鑰。 |

iOS 27 及以上透過原生服務控制 iPhone。iOS 18 至 26 使用 XCTest 工作階段，需要在 iPhone 的開發者設定裡開啟 UI 自動化。應用程式也可安裝到 iPadOS 18 或更高版本的 iPad。

iPhone 應用程式使用你自備的模型帳號。電腦上編碼代理程式的訂閱不會自動為 Poki 設好帳號。若只想在現有編碼代理程式中使用 Poki MCP，請按 [MCP 安裝說明](install.md) 操作，MCP 使用該客戶端已有的模型存取權。

## 安裝說明

### 一鍵安裝（推薦）

需要你做的只有連接並解鎖 iPhone、按提示登入帳號，以及完成 iPhone 權限、本機連線和模型帳號設定。

把下面這段發給 Claude Code、Codex 等代理程式：

```text
從 https://github.com/JosssphZhou/poki 把 Poki 安裝到我的 iPhone 上
```

代理程式會按 [install-poki 技能](../skills/install-poki/SKILL.md) 執行 `bin/install-iphone.mjs`，完成能自動處理的步驟。你只需處理 iOS 要求本人完成的操作：在 Mac 上的 Poki Setup 視窗輸入 Apple 帳號，在 iPhone 上點「信任」、開啟開發者模式、信任開發者，然後開啟 Poki。首次開啟會請求開啟自動化模式，點「繼續」並輸入 iPhone 密碼即可。如果取消，重新開啟 Poki 後會再次詢問。每一步需要你操作時，代理程式都會說明。免費 Apple 帳號也能用。

目前安裝器統一選擇 Beta，歷史 Stable、Alpha 和 Pre-alpha 偏好也會轉為 Beta；沒有可用 Beta 時停止。已安裝的舊版 Poki Setup 可能仍按原通道選擇，請以本次執行顯示的版本為準。

沒有 Node.js 24，或使用 Windows？裝好 Poki Setup 後，同一段提示也能用，代理程式會呼叫其內建命令列工具。Poki Setup 選單也能複製安裝提示，Mac 上位於 `Poki > Copy Prompt for Your Agent`，Windows 上位於 `Settings > Use an agent`。

如果安裝器讀取 GitHub 發布資訊時遇到 403 或 429，通常是同一網路共用的匿名請求額度已耗盡。可以換網路或代理節點重試，也可以等一小時。

### 使用 Poki Setup 安裝

從包含安裝器的最新 [Beta 發布](https://github.com/JosssphZhou/poki/releases) 下載 macOS 版 Poki Setup（`.dmg`）或 Windows 版（`.exe`，由 [ZhehanZhang](https://github.com/ZhehanZhang) 貢獻），然後按視窗提示操作。詳細步驟見 [Poki Setup](../desktop/README.md)。

### 執行第一個任務

安裝器核對已安裝版本，且你完成本機連線和模型帳號設定後，開啟 Poki 並傳送：

```text
在備忘錄中新建一則標題為「Poki Demo」的筆記，內文分三行寫 Milk、Eggs、Coffee。完成後開啟這則筆記，不修改現有筆記。
```

在備忘錄中核對新筆記：標題應為「Poki Demo」，內文三行分別為 Milk、Eggs、Coffee。不能只憑對話中的完成回覆判斷成功。如果沒有備忘錄應用程式或設定尚未完成，先處理對應步驟。中斷後重試前，先檢查筆記是否已經建立。

## 常見問題

**Windows 能安裝嗎？** 可以。Windows 版 Poki Setup 和 Mac 版一樣支援安裝、配對和重新簽署。先安裝 Apple Devices 或 iTunes，讓電腦能辨識 iPhone。詳見 [Poki Setup](../desktop/README.md)。

**安裝後還需要電腦嗎？** 執行任務不需要，Poki 在 iPhone 上獨立執行。免費 Apple 帳號需要重新簽署，可保持電腦上的 Poki Setup 執行，也可以在 Poki 內登入 Apple 帳號，讓 iPhone 自己重新簽署。若登入失敗，請改用電腦上的 Poki Setup。詳見[哪些需要保持執行](../skills/install-poki/SKILL.md#what-to-keep-running)。

**免費 Apple 帳號能用嗎？7 天是什麼意思？** 能用，但 Apple 為免費帳號簽發的應用程式簽署只有 7 天有效期。Poki Setup 保持執行、電腦未睡眠且能連線 iPhone 時，會每 6 小時檢查並為剩餘有效期不超過 2 天的應用程式重新簽署。未重新簽署的應用程式到期後無法開啟，Poki 會在最後 2 天提醒。詳見[沒有付費開發者帳號](../skills/install-poki/SKILL.md#no-paid-developer-account)。

**需要哪款 iPhone 和哪個 iOS 版本？** iOS 18 或更高版本，即 iPhone XS、XR、SE（第 2 代）或更新機型，也支援安裝到 iPadOS 18 或更高版本的 iPad。目前真機測試使用 iOS 27，iOS 18 至 26 的控制方式不同，尚未在真機驗證。詳見[驗證記錄與已知限制](verification.md)。

**需要自己的模型帳號嗎？** 需要。可用 ChatGPT Plus 或 Pro 登入，填寫 Anthropic、OpenAI、Gemini、DeepSeek、OpenRouter 或 OpenCode Go 的 API 金鑰，或接入自己的 OpenAI 相容服務。語音對話還需要語音模型金鑰。詳見[需要準備什麼](#需要準備什麼)。

**看不到更新，例如在中國大陸的網路上，怎麼辦？** Poki 從 GitHub 檢查更新，部分網路無法存取，或遇到 403、429 請求限制。可換網路或代理節點，也可以在電腦上的 Poki Setup 中使用 Renew 更新。詳見[更新 Poki](#更新-poki)。

**Poki 會修改手機裡的內容嗎？操作前會詢問嗎？** Poki 會在真實應用程式裡執行你的要求，包括傳送訊息，螢幕內容會傳送到你設定的模型服務。付款、刪除和錢包中的操作始終需要確認。其他敏感步驟，例如傳送訊息或輸入密碼，可以在 `Settings > Approvals` 中選擇詢問方式，也可以選擇不詢問。詳見[已知問題](#已知問題)。

## 更新 Poki

- **在 iPhone 上更新。** 開啟 Poki 的簽署與更新頁面：目前版本位於 `Settings > Signing & Updates`，舊版本可能放在「連線」下面。有新組建時，頁面會提供下載和安裝。如果要求先登入，說明 Poki 從電腦安裝，手機上還沒有你的 Apple 帳號。請使用安裝時的帳號登入，或改用電腦更新。
- **從電腦更新。** Poki Setup 中的 Renew 會將所選通道的最新組建安裝到現有應用程式上。Mac 使用者也可以告訴代理程式「更新我 iPhone 上的 Poki」。install-poki 技能有獨立的更新流程，會先核對已安裝版本和簽署身分。
- 如果更新停在「正在完成更新」，請在應用程式切換器中向上滑動關閉 Poki，再重新開啟並檢視設定中的版本。版本未變化時，請用電腦上的 Poki Setup 更新。不要為了修復更新而刪除 Poki，刪除應用程式會一併刪除對話。

發布通道以及組建從 Alpha 進入 Beta 的方式見[發布通道](release-channels.md)。

## 試跑一個任務

開啟 Poki，在輸入框裡寫下任務，例如「查一下明天的天氣，告訴我需不需要帶傘」，也可以點首頁的應用程式來發起任務。Poki 會操作螢幕上的應用程式，在動態島和鎖定畫面上顯示每一步，並按你的設定徵求許可。

你也可以不用開啟 Poki：長按動作按鈕與它交談，或透過捷徑和 Siri 呼叫 Talk to Poki、Send Task to Poki。這樣傳送的任務會透過通知回覆。在 iPhone Duo 的分割畫面中，Poki 可以同時操作並排的兩個應用程式。

> **注意：** Poki 控制的是真實 iPhone。你讓它發訊息或付款，它就會執行。

## 已知問題

- Poki 操作的是真實 iPhone，會按要求傳送訊息或付款。螢幕內容會傳送到你設定的模型服務。
- 如果無法在 iPhone 上登入 Apple 帳號，請用電腦上的 Poki Setup 重新簽署和更新。
- 真機支援目前只在中文介面、直向的 iPhone 上驗證過，不支援橫向。
- 本版本尚未在低於 iOS 27 的 iPhone 真機或 iPad 上測試。較老或較小的 iPhone 執行立體小熊和首頁動畫時可能更熱、更慢。低耗電模式或減少動態效果會改為顯示靜態小熊。
- 免費 Apple 帳號的簽署有效期為 7 天。請確保電腦上的 Poki Setup 能連線 iPhone，或在到期前手動重新簽署。
- 從 GitHub 讀取發布資訊可能遇到 403 或 429，通常是多人共用網路所致。可換網路或代理節點重試，也可以等一小時。

更多限制和測試結果見[驗證記錄與已知限制](verification.md)。

## 路線圖

這裡只列方向，不承諾日期。已發布功能見 [CHANGELOG.md](../CHANGELOG.md)。

**Released in 0.4 Beta**

- iPhone 應用程式在設定完成後無需電腦即可執行任務，鎖定畫面和動態島支援核准。
- 使用免費 Apple 帳號，透過 Mac 或 Windows 上的代理程式或 Poki Setup 安裝。
- iOS 27 及以上的原生控制，以及 Poki 內建瀏覽器中的網頁任務。
- 立體小熊新首頁、語音對話、動作按鈕、對話封存、iPhone Duo 分割畫面、可調介面大小與深色模式。

**進行中**

- 更穩定的更新下載與統一的更新處理機制。
- 更多介面語言。

**規劃中**

- 在真機上驗證更多 iPhone、iOS 版本和螢幕語言。
- 支援更多模型提供商。

## 其他工具

[Poki MCP](poki-mcp.md) 將電腦上的代理程式連接到 iPhone 或 iOS 模擬器，這項早期工具已停止更新。

[Poki Agent](poki-mcp.md#try-a-task-with-poki-agent) 是支援 iMessage 和 Telegram 的終端機代理程式，安裝與使用方式請見連結中的指南。

## 免責聲明

Poki 是獨立的開源專案，與 Apple、OpenAI 以及它所操作的任何 App 或網站的開發者都沒有關聯，也未獲得其背書。iPhone 是 Apple Inc. 的商標。

自動化操作第三方 App 和網站可能違反其服務條款。是否在特定服務上使用 Poki，請自行判斷。Poki 在你的裝置和帳號上做的事由你負責，包括它發送的訊息、做出的變更，以及因此造成的任何帳號限制。

Poki 依「現狀」提供，不附帶任何擔保，詳見 AGPL-3.0 授權條款。

## 授權條款

Poki 的程式碼以 [AGPL-3.0-only 授權條款](../LICENSE) 開源。

Poki 小熊、App 圖示和 Poki 的其他美術作品不在此授權範圍內。你可以用截圖介紹 Poki；分支版本需要使用自己的名稱和美術。詳見 [BRAND.md](../BRAND.md)。

Copyright (c) 2026 Joseph Zhou (周瑟夫) and contributors. 開源相依套件和第三方素材保留各自的授權條款，詳見 [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md)。想參與貢獻，請見 [CONTRIBUTING.md](../CONTRIBUTING.md)。
