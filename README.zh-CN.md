<p align="center">
  <img src="docs/images/poki-icon.png" width="72" height="72" alt="Poki icon">
</p>

<h1 align="center">Poki 像你一样使用你的 iPhone</h1>

<p align="center">
  <img src="docs/images/poki-home.gif" width="720" alt="Poki 官网首页动画">
</p>

<p align="center">
  <a href="README.md">English</a> | 简体中文 | <a href="README.zh-TW.md">繁體中文</a> | <a href="README.ja.md">日本語</a> | <a href="README.ko.md">한국어</a> | <a href="README.es.md">Español</a><br>
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

Poki 是能操作你 iPhone 的应用。它会读取屏幕，在真实应用中点击、输入和滚动。你可以选择它如何征求许可；付款、删除和钱包中的操作始终需要确认。

**Poki App** 直接在 iPhone 上运行。你在对话里交代任务，它就到其他应用中执行。通过 Mac 或 Windows 电脑安装一次后，执行任务不再需要电脑。

每个版本的变化见 [CHANGELOG.md](CHANGELOG.md)。

## 在 iPhone 上安装 Poki

首次安装需要一台 Mac 或 Windows 电脑。

- **Mac 用户**可以让智能体安装 Poki，也可以下载 macOS 版 Poki Setup，按窗口提示操作。
- **Windows 用户**可以下载 Windows 版 Poki Setup，按窗口提示操作。请先安装 Apple Devices 或 iTunes，让电脑能通过 USB 识别 iPhone。智能体也可以调用 Poki Setup 内置的命令行工具。
- **安装后**，Poki 在 iPhone 上独立执行任务。免费 Apple 账户的签名有效期为 7 天，电脑上的 Poki Setup 保持运行时可以续签。详见[常见问题](#常见问题)。

### 让智能体安装（推荐）

把下面这段发给 Claude Code、Codex 等智能体：

```text
从 https://github.com/JosssphZhou/poki 把 Poki 安装到我的 iPhone 上
```

智能体会按 [install-poki 技能](skills/install-poki/SKILL.md)运行 `bin/install-iphone.mjs`，完成能自动处理的步骤。你只需处理 iOS 要求本人完成的操作：在 Mac 上的 Poki Setup 窗口输入 Apple 账户，在 iPhone 上点「信任」、开启开发者模式、信任开发者，然后打开 Poki。首次打开会请求开启自动化模式，点「继续」并输入 iPhone 密码即可。如果取消，重新开启 Poki 后会再次询问。每一步需要你操作时，智能体都会说明。免费 Apple 账户也能用。

安装器默认使用 Alpha 通道，你也可以让智能体改用 Beta 等其他通道。构建先进入 Alpha，经过更多测试后，同一构建再进入 Beta。

没有 Node.js 24，或使用 Windows？装好 Poki Setup 后，同一段提示也能用，智能体会调用其内置命令行工具。Poki Setup 菜单也能复制安装提示，Mac 上位于 Poki > Copy Prompt for Your Agent，Windows 上位于 Settings > Use an agent。

如果安装器读取 GitHub 发布信息时遇到 403 或 429，通常是同一网络共用的匿名请求额度已耗尽。可以换网络或代理节点重试，也可以等一小时。

### 使用 Poki Setup 安装

想自己点击安装？从 [Alpha 发布页](https://github.com/JosssphZhou/poki/releases/tag/app-alpha-latest)下载 macOS 版 Poki Setup（`.dmg`）或 Windows 版（`.exe`，由 [ZhehanZhang](https://github.com/ZhehanZhang) 贡献），按窗口提示操作。Beta 发布页提供相同的 Poki Setup 文件。在设置里选择通道前，Poki Setup 会安装最新 Stable 版；没有 Stable 时则安装 Beta 版。详细步骤见 [Poki Setup](desktop/README.md)。

### 需要准备什么

| 项目 | 要求 |
| --- | --- |
| iPhone | iOS 18 或更高版本，即 iPhone XS、XR、SE（第 2 代）或更新机型。Poki 已在运行 iOS 27 的 iPhone 真机上测试。 |
| 电脑 | macOS 14 或更高版本的 Mac，或已安装 Apple Devices 或 iTunes 的 Windows 电脑（x64）。在 Mac 上通过脚本让智能体安装还需要 Node.js 24 或更高版本。 |
| 数据线与账户 | USB 数据线和 Apple 账户。免费账户签名有效期为 7 天，Poki Setup 可以续签。 |
| 连接 | iPhone 上需要能将 10.7.0.1 连回本机的 VPN 应用。可用 App Store 上免费的 LocalDevVPN，也可按 Poki 的说明配置 Karing 或 Shadowrocket。 |
| 模型账户 | 需要自备。用 ChatGPT Plus 或 Pro 套餐登录最方便，也可以填写 Anthropic、OpenAI、Gemini、DeepSeek 或 OpenRouter 的 API 密钥，或接入自己的 OpenAI 兼容服务。Claude 订阅不能直接登录，请使用 Anthropic API 密钥。 |

iOS 27 及以上通过原生服务控制 iPhone。iOS 18 至 26 使用 XCTest 会话，需要在 iPhone 的开发者设置里开启 UI 自动化。应用也可安装到 iPadOS 18 或更高版本的 iPad。

### 常见问题

**Windows 能安装吗？** 可以。Windows 版 Poki Setup 和 Mac 版一样支持安装、配对和续签。先安装 Apple Devices 或 iTunes，让电脑能识别 iPhone。详见 [Poki Setup](desktop/README.md)。

**安装后还需要电脑吗？** 执行任务不需要，Poki 在 iPhone 上独立运行。免费 Apple 账户需要续签，可保持电脑上的 Poki Setup 运行，也可以在 Poki 内登录 Apple 账户，让 iPhone 自己续签。若登录失败，请改用电脑上的 Poki Setup。详见[哪些需要保持运行](skills/install-poki/SKILL.md#what-to-keep-running)。

**免费 Apple 账户能用吗？7 天是什么意思？** 能用，但 Apple 为免费账户签发的应用签名只有 7 天有效期。Poki Setup 保持运行、电脑未睡眠且能连接 iPhone 时，会每 6 小时检查并为剩余有效期不超过 2 天的应用续签。未续签的应用到期后无法打开，Poki 会在最后 2 天提醒。详见[没有付费开发者账户](skills/install-poki/SKILL.md#no-paid-developer-account)。

**需要哪款 iPhone 和哪个 iOS 版本？** iOS 18 或更高版本，即 iPhone XS、XR、SE（第 2 代）或更新机型，也支持安装到 iPadOS 18 或更高版本的 iPad。目前真机测试使用 iOS 27，iOS 18 至 26 的控制方式不同，尚未在真机验证。详见[验证记录与已知限制](docs/verification.md)。

**需要自己的模型账户吗？** 需要。可用 ChatGPT Plus 或 Pro 登录，填写 Anthropic、OpenAI、Gemini、DeepSeek 或 OpenRouter 的 API 密钥，或接入自己的 OpenAI 兼容服务。语音对话还需要语音模型密钥。详见[需要准备什么](#需要准备什么)。

**看不到更新，例如在中国大陆的网络上，怎么办？** Poki 从 GitHub 检查更新，部分网络无法访问，或遇到 403、429 请求限制。可换网络或代理节点，也可以在电脑上的 Poki Setup 中使用 Renew 更新。详见[更新 Poki](#更新-poki)。

**Poki 会修改手机里的内容吗？操作前会询问吗？** Poki 会在真实应用里执行你的要求，包括发送消息，屏幕内容会发送到你配置的模型服务。付款、删除和钱包中的操作始终需要确认。其他敏感步骤，例如发送消息或输入密码，可以在设置 > 审批中选择询问方式，也可以选择不询问。详见[已知问题](#已知问题)。

## 更新 Poki

- **在 iPhone 上更新。** 0.4.0 中打开设置 > 连接 > 签名与更新。有新构建时，页面会提供下载和安装。如果要求先登录，说明 Poki 从电脑安装，手机上还没有你的 Apple 账户。请使用安装时的账户登录，或改用电脑更新。
- **从电脑更新。** Poki Setup 中的 Renew 会将所选通道的最新构建安装到现有应用上。Mac 用户也可以告诉智能体「更新我 iPhone 上的 Poki」。install-poki 技能有独立的更新流程，会先核对已安装版本和签名身份。
- 如果更新停在「正在完成更新」，请在应用切换器中划掉 Poki，再重新打开并查看设置中的版本。版本未变化时，请用电脑上的 Poki Setup 更新。不要为了修复更新而删除 Poki，删除应用会一并删除对话。

发布通道以及构建从 Alpha 进入 Beta 的方式见[发布通道](docs/release-channels.md)。

## 已知问题

- Poki 操作的是真实 iPhone，会按要求发送消息或付款。屏幕内容会发送到你配置的模型服务。
- 如果无法在 iPhone 上登录 Apple 账户，请用电脑上的 Poki Setup 续签和更新。
- 真机支持目前只在中文界面、竖屏的 iPhone 上验证过，不支持横屏。
- 本版本尚未在低于 iOS 27 的 iPhone 真机或 iPad 上测试。较老或较小的 iPhone 运行立体小熊和首页动画时可能更热、更慢。低电量模式或减弱动态效果会改为显示静态小熊。
- 免费 Apple 账户的签名有效期为 7 天。请确保电脑上的 Poki Setup 能连接 iPhone，或在到期前手动续签。
- 从 GitHub 读取发布信息可能遇到 403 或 429，通常是多人共用网络所致。可换网络或代理节点重试，也可以等一小时。

更多限制和测试结果见[验证记录与已知限制](docs/verification.md)。

## 试跑一个任务

打开 Poki，在输入框里写下任务，例如「查一下明天的天气，告诉我需不需要带伞」，也可以点首页的应用来发起任务。Poki 会操作屏幕上的应用，在灵动岛和锁屏上显示每一步，并按你的设置征求许可。

你也可以不用打开 Poki：长按操作按钮与它交谈，或通过快捷指令和 Siri 调用 Talk to Poki、Send Task to Poki。这样发送的任务会通过通知回复。

> **注意：** Poki 控制的是真实 iPhone。你让它发消息或付款，它就会执行。

## 路线图

这里只列方向，不承诺日期。已发布功能见 [CHANGELOG.md](CHANGELOG.md)。

**0.4.0 Beta 已发布**

- iPhone App 在设置完成后无需电脑即可执行任务，锁屏和灵动岛支持审批。
- 使用免费 Apple 账户，通过 Mac 或 Windows 上的智能体或 Poki Setup 安装。
- iOS 27 及以上的原生控制，以及 Poki 内置浏览器中的网页任务。
- 立体小熊新首页、语音对话、操作按钮、对话归档和深色模式。

**进行中**

- 将更新迁到更稳定的下载源，GitHub 保留为备用。
- 将多个更新通道合成一个。
- 更多界面语言。

**计划中**

- 在真机上验证更多 iPhone、iOS 版本和屏幕语言。
- 支持更多模型提供商。

## 文档

| 主题 | 文档 |
| --- | --- |
| 各版本变化 | [CHANGELOG.md](CHANGELOG.md) |
| 让智能体安装 iPhone App | [install-poki 技能](skills/install-poki/SKILL.md) |
| Mac 和 Windows 上的 Poki Setup | [Poki Setup](desktop/README.md) |
| 发布通道和版本晋级方式 | [发布通道](docs/release-channels.md) |
| 测试结果、已知限制和免责声明 | [验证与限制](docs/verification.md) |
| 路线图 | [路线图](#路线图) |

## Star History

<a href="https://www.star-history.com/?repos=JosssphZhou%2Fpoki&type=date&legend=top-left">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=JosssphZhou/poki&type=date&theme=dark&legend=top-left">
    <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=JosssphZhou/poki&type=date&legend=top-left">
    <img alt="Star History chart" src="https://api.star-history.com/chart?repos=JosssphZhou/poki&type=date&legend=top-left">
  </picture>
</a>

## 核心贡献者

<!-- CORE-CONTRIBUTORS:START -->
<table>
  <tbody>
    <tr>
      <td align="center" valign="top" width="33%"><a href="https://github.com/makirqi-alt"><img src="https://avatars.githubusercontent.com/u/295395617?v=4&size=240" width="120" height="120" alt="makirqi-alt"/><br /><sub><b>makirqi-alt</b></sub></a><br />提交了 Poki 的第一个问题 <a href="https://github.com/JosssphZhou/poki/issues/1">#1</a>：在 iOS 18.6.2 上截图正常，辅助功能和触控不可用，哪些能用哪些不能写得很清楚。</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/ZhehanZhang"><img src="https://avatars.githubusercontent.com/u/67270559?v=4&size=240" width="120" height="120" alt="ZhehanZhang"/><br /><sub><b>ZhehanZhang</b></sub></a><br />Poki 伟大的共同创造者。</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/edge369"><img src="https://avatars.githubusercontent.com/u/63720633?v=4&size=240" width="120" height="120" alt="edge369"/><br /><sub><b>edge369</b></sub></a><br />在 <a href="https://github.com/JosssphZhou/poki/pull/14">#14</a> 中让 Poki 能在路由器上运行，Mac 关机时也能通过 Telegram 操作 iPhone；<a href="https://github.com/JosssphZhou/poki/pull/15">#15</a>、<a href="https://github.com/JosssphZhou/poki/pull/17">#17</a> 和 <a href="https://github.com/JosssphZhou/poki/issues/19">#19</a> 随后跟进。</td>
    </tr>
    <tr>
      <td align="center" valign="top" width="33%"><a href="https://github.com/mawenhao1028"><img src="https://avatars.githubusercontent.com/u/70818670?v=4&size=240" width="120" height="120" alt="mawenhao1028"/><br /><sub><b>mawenhao1028</b></sub></a><br />在 <a href="https://github.com/JosssphZhou/poki/issues/6">#6</a> 中报告 macOS 27.2 上 usbmuxd 列不出任何 iPhone；Poki 现在会直接说明这一点，以及辅助程序为何提前停止（<a href="https://github.com/JosssphZhou/poki/issues/59">#59</a>）。</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/igc110"><img src="https://avatars.githubusercontent.com/u/241411380?v=4&size=240" width="120" height="120" alt="igc110"/><br /><sub><b>igc110</b></sub></a><br />在 <a href="https://github.com/JosssphZhou/poki/issues/10">#10</a> 中查明真机点按慢的原因，随后的修复让点按快了约三分之一。</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/carrotciallo"><img src="https://avatars.githubusercontent.com/u/69567867?v=4&size=240" width="120" height="120" alt="carrotciallo"/><br /><sub><b>carrotciallo</b></sub></a><br />在 <a href="https://github.com/JosssphZhou/poki/issues/16">#16</a> 中把 Poki 移植到 Linux，并在 iPhone 真机上通过 USB、局域网和 Tailscale 验证；README 现已指向该移植版。</td>
    </tr>
    <tr>
      <td align="center" valign="top" width="33%"><a href="https://github.com/guangtouge82"><img src="https://avatars.githubusercontent.com/u/269691899?v=4&size=240" width="120" height="120" alt="guangtouge82"/><br /><sub><b>guangtouge82</b></sub></a><br />在 <a href="https://github.com/JosssphZhou/poki/issues/18">#18</a> 中把 iPhone 真机触控失败追查到缺少 display service；现在 Poki 会说明没有发送任何输入，并指向 prepare-device。</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/Dreaminmaster"><img src="https://avatars.githubusercontent.com/u/189544503?v=4&size=240" width="120" height="120" alt="Dreaminmaster"/><br /><sub><b>Dreaminmaster</b></sub></a><br />修复了损坏的路由缓存中断无关 Agent 任务的问题（<a href="https://github.com/JosssphZhou/poki/issues/21">#21</a>、<a href="https://github.com/JosssphZhou/poki/pull/22">#22</a>），随后在 <a href="https://github.com/JosssphZhou/poki/pull/37">#37</a> 中让 Agent 复用操作后已读取的屏幕。</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/PeterKingXu1s"><img src="https://avatars.githubusercontent.com/u/89392314?v=4&size=240" width="120" height="120" alt="PeterKingXu1s"/><br /><sub><b>PeterKingXu1s</b></sub></a><br />在 <a href="https://github.com/JosssphZhou/poki/issues/25">#25</a> 中报告了 iMessage 任务不会被自然语言的停止请求打断；现在 Poki 会回复任务中途的消息，并提示使用 /stop。</td>
    </tr>
    <tr>
      <td align="center" valign="top" width="33%"><a href="https://github.com/ScottH1122"><img src="https://avatars.githubusercontent.com/u/142722955?v=4&size=240" width="120" height="120" alt="ScottH1122"/><br /><sub><b>ScottH1122</b></sub></a><br />在 <a href="https://github.com/JosssphZhou/poki/issues/27">#27</a> 和 <a href="https://github.com/JosssphZhou/poki/issues/28">#28</a> 中复现了两个 Agent 缺陷，随后合并了七项修复和测试修整，从已取消的输入锁（<a href="https://github.com/JosssphZhou/poki/pull/102">#102</a>）到无效的触控坐标（<a href="https://github.com/JosssphZhou/poki/pull/136">#136</a>）。</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/jiahuipaung"><img src="https://avatars.githubusercontent.com/u/70688286?v=4&size=240" width="120" height="120" alt="jiahuipaung"/><br /><sub><b>jiahuipaung</b></sub></a><br />在 <a href="https://github.com/JosssphZhou/poki/pull/34">#34</a> 中修复了 iPhone 局域网地址变化后 RemotePairing 连接失效的问题（<a href="https://github.com/JosssphZhou/poki/issues/30">#30</a>）；真机重连只用了 768 毫秒。</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/Zeno6898"><img src="https://avatars.githubusercontent.com/u/229920081?v=4&size=240" width="120" height="120" alt="Zeno6898"/><br /><sub><b>Zeno6898</b></sub></a><br />在 <a href="https://github.com/JosssphZhou/poki/issues/35">#35</a> 和 <a href="https://github.com/JosssphZhou/poki/issues/40">#40</a> 中实地测试了 iPhone 应用，覆盖蜂窝网络和 Windows，促成了首次设置需要 Wi-Fi 的说明（<a href="https://github.com/JosssphZhou/poki/issues/138">#138</a>）；还报告了 <a href="https://github.com/JosssphZhou/poki/issues/162">#162</a>。</td>
    </tr>
    <tr>
      <td align="center" valign="top" width="33%"><a href="https://github.com/scy7796"><img src="https://avatars.githubusercontent.com/u/282529358?v=4&size=240" width="120" height="120" alt="scy7796"/><br /><sub><b>scy7796</b></sub></a><br />在 <a href="https://github.com/JosssphZhou/poki/pull/39">#39</a> 中修复了 Windows 主机经 RemotePairing 连接时每次点按都失败的问题；修复后 5 次点按全部成功。</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/foshanfm"><img src="https://avatars.githubusercontent.com/u/24779370?v=4&size=240" width="120" height="120" alt="foshanfm"/><br /><sub><b>foshanfm</b></sub></a><br />在 <a href="https://github.com/JosssphZhou/poki/issues/42">#42</a> 中通过 Tailscale 在真机上做了一次保险条款核对；这份报告推动了更清晰的 USB 报错，以及按会话切换连接方式。</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/xiaweiyi713"><img src="https://avatars.githubusercontent.com/u/208608622?v=4&size=240" width="120" height="120" alt="xiaweiyi713"/><br /><sub><b>xiaweiyi713</b></sub></a><br />录制了 Poki 操作 iPhone 真机的演示视频，让新访客在安装之前就能看到它能做什么。</td>
    </tr>
    <tr>
      <td align="center" valign="top" width="33%"><a href="https://github.com/fucknima"><img src="https://avatars.githubusercontent.com/u/18666223?v=4&size=240" width="120" height="120" alt="f&#42;&#42;&#42;&#42;&#42;&#42;&#42;"/><br /><sub><b>f&#42;&#42;&#42;&#42;&#42;&#42;&#42;</b></sub></a><br />在 <a href="https://github.com/JosssphZhou/poki/pull/68">#68</a> 中把 OpenCode Go 加为 iPhone 应用的模型账号，带独立的钥匙串凭据和独立的模型选择。</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/owensn951954688"><img src="https://avatars.githubusercontent.com/u/312761798?v=4&size=240" width="120" height="120" alt="owensn951954688"/><br /><sub><b>owensn951954688</b></sub></a><br />在 <a href="https://github.com/JosssphZhou/poki/issues/69">#69</a> 中给出了 Runner 空闲约 25 分钟后配对失败的完整时间线；设置页现在会指向回环和配对检查（<a href="https://github.com/JosssphZhou/poki/issues/70">#70</a>）。</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/kira-ariaki"><img src="https://avatars.githubusercontent.com/u/257352493?v=4&size=240" width="120" height="120" alt="kira-ariaki"/><br /><sub><b>kira-ariaki</b></sub></a><br />让批量调用在设备不明确时给出提示而不是崩溃（<a href="https://github.com/JosssphZhou/poki/pull/74">#74</a>），并新增 POKI_MCP_DEVICE（<a href="https://github.com/JosssphZhou/poki/pull/75">#75</a>）和可选的按任务审批（<a href="https://github.com/JosssphZhou/poki/pull/77">#77</a>）。</td>
    </tr>
    <tr>
      <td align="center" valign="top" width="33%"><a href="https://github.com/Purelite"><img src="https://avatars.githubusercontent.com/u/9334469?v=4&size=240" width="120" height="120" alt="Purelite"/><br /><sub><b>Purelite</b></sub></a><br />修复配对设置把人带到错误设置页面的问题，开发者模式和 UI 自动化步骤现在会打开正确的页面（<a href="https://github.com/JosssphZhou/poki/pull/137">#137</a>）。</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/heyallencao"><img src="https://avatars.githubusercontent.com/u/258265534?v=4&size=240" width="120" height="120" alt="heyallencao"/><br /><sub><b>heyallencao</b></sub></a><br />在 <a href="https://github.com/JosssphZhou/poki/pull/139">#139</a> 中修复读屏超过调用期限的问题，并为持续变慢的 Runner 响应补了回归测试。</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/whiteluw"><img src="https://avatars.githubusercontent.com/u/86720151?v=4&size=240" width="120" height="120" alt="whiteluw"/><br /><sub><b>whiteluw</b></sub></a><br />在 <a href="https://github.com/JosssphZhou/poki/pull/326">#326</a> 中修复 iPhone 上三维小熊初始化时的闪退。</td>
    </tr>
  </tbody>
</table>
<!-- CORE-CONTRIBUTORS:END -->

## 特别贡献者

<table>
  <tbody>
    <tr>
      <td align="center" valign="top" width="33%"><a href="https://github.com/yulunRyanw"><img src="https://avatars.githubusercontent.com/u/216360668?v=4&size=240" width="120" height="120" alt="yulunRyanw"/><br /><sub><b>yulunRyanw</b></sub></a><br />为 0.4.0 改版提交了完整的界面设计，涵盖对话、实时活动、设置和首次使用流程（<a href="https://github.com/JosssphZhou/poki/pull/250">#250</a>, <a href="https://github.com/JosssphZhou/poki/pull/256">#256</a>, <a href="https://github.com/JosssphZhou/poki/pull/268">#268</a>），为新界面提供了方向。</td>
    </tr>
  </tbody>
</table>

## 感谢墙

感谢每一位提交过 Issue 或 Pull Request 的朋友，你们的反馈与修复让 Poki 变得更好。

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
      <td align="center" valign="top" width="20%"><a href="https://github.com/whiteluw"><img src="https://avatars.githubusercontent.com/u/86720151?v=4&size=160" width="80" height="80" alt="whiteluw"/><br /><sub><b>whiteluw</b></sub></a></td>
    </tr>
    <tr>
      <td align="center" valign="top" width="20%"><a href="https://github.com/windywendyday"><img src="https://avatars.githubusercontent.com/u/65647922?v=4&size=160" width="80" height="80" alt="windywendyday"/><br /><sub><b>windywendyday</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/xiaweiyi713"><img src="https://avatars.githubusercontent.com/u/208608622?v=4&size=160" width="80" height="80" alt="xiaweiyi713"/><br /><sub><b>xiaweiyi713</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/yulunRyanw"><img src="https://avatars.githubusercontent.com/u/216360668?v=4&size=160" width="80" height="80" alt="yulunRyanw"/><br /><sub><b>yulunRyanw</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/zcyoung2000"><img src="https://avatars.githubusercontent.com/u/62181891?v=4&size=160" width="80" height="80" alt="zcyoung2000"/><br /><sub><b>zcyoung2000</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/Zeno6898"><img src="https://avatars.githubusercontent.com/u/229920081?v=4&size=160" width="80" height="80" alt="Zeno6898"/><br /><sub><b>Zeno6898</b></sub></a></td>
    </tr>
    <tr>
      <td align="center" valign="top" width="20%"><a href="https://github.com/zqy5608"><img src="https://avatars.githubusercontent.com/u/14949471?v=4&size=160" width="80" height="80" alt="zqy5608"/><br /><sub><b>zqy5608</b></sub></a></td>
    </tr>
  </tbody>
</table>
<!-- THANKS-WALL:END -->

## 其他工具

[Poki MCP](docs/poki-mcp.md) 将电脑上的智能体连接到 iPhone 或 iOS 模拟器，这个早期工具已停止更新。

[Poki Agent](docs/poki-mcp.md#try-a-task-with-poki-agent) 是支持 iMessage 和 Telegram 渠道的终端智能体，安装和使用方式见链接中的指南。

## 免责声明

Poki 是独立的开源项目，与 Apple、OpenAI 以及它所操作的任何应用或网站的开发者均无关联，也未获得其认可。iPhone 是 Apple Inc. 的商标。

自动操作第三方应用和网站可能违反其服务条款，请自行判断是否在相应服务上使用 Poki。Poki 在你的设备和账号上执行的操作由你负责，包括它发送的消息、作出的更改，以及由此导致的账号限制。

Poki 按「原样」提供，不附带任何担保，具体以 AGPL-3.0 许可证为准。

## 开源许可

Poki 的代码基于 [AGPL-3.0-only 许可证](LICENSE)开源。

Poki 小熊、应用图标和 Poki 的其他美术作品不在这一许可证范围内。你可以用截图介绍 Poki；分叉版本需要使用自己的名称和美术。详见 [BRAND.md](BRAND.md)。

Copyright (c) 2026 Joseph Zhou (周瑟夫) and contributors。开源依赖项和第三方素材保留各自的许可证，详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。如需参与贡献，请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 致谢

Poki 使用的开源依赖和素材见[第三方声明](THIRD_PARTY_NOTICES.md)。
