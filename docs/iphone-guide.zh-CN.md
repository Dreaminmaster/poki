# Poki iPhone 使用指南

[English](iphone-guide.md) | 简体中文 | [繁體中文](iphone-guide.zh-TW.md) | [日本語](iphone-guide.ja.md) | [한국어](iphone-guide.ko.md) | [Español](iphone-guide.es.md)

本指南涵盖 Poki iPhone 应用的完整环境要求、安装细节、更新方法、常见问题、已知限制和任务示例。

每个版本的变化见 [CHANGELOG.md](../CHANGELOG.md)。

## 需要准备什么

| 项目 | 要求 |
| --- | --- |
| iPhone | iOS 18 或更高版本，即 iPhone XS、XR、SE（第 2 代）或更新机型。Poki 已在运行 iOS 27 的 iPhone 真机上测试。 |
| 电脑 | macOS 14 或更高版本的 Mac，或已安装 Apple Devices 或 iTunes 的 Windows 电脑（x64）。在 Mac 上通过脚本让智能体安装还需要 Node.js 24 或更高版本。 |
| 数据线与账户 | USB 数据线和 Apple 账户。免费账户签名有效期为 7 天，Poki Setup 可以续签。 |
| 连接 | iPhone 上需要能将 `10.7.0.1` 连回本机的 VPN 应用。可用 App Store 上免费的 LocalDevVPN，也可按 Poki 的说明配置 Karing 或 Shadowrocket。 |
| 模型账户 | 需要自备。用 ChatGPT Plus 或 Pro 套餐登录最方便，也可以填写 Anthropic、OpenAI、Gemini、DeepSeek、OpenRouter 或 OpenCode Go 的 API 密钥，或接入自己的 OpenAI 兼容服务。Claude 订阅不能直接登录，请使用 Anthropic API 密钥。 |

iOS 27 及以上通过原生服务控制 iPhone。iOS 18 至 26 使用 XCTest 会话，需要在 iPhone 的开发者设置里开启 UI 自动化。应用也可安装到 iPadOS 18 或更高版本的 iPad。

iPhone App 使用你自备的模型账号，电脑上编码智能体的订阅不会自动为 Poki 配好账号。若只想在现有编码智能体中使用 Poki MCP，请按 [MCP 安装说明](install.md)操作，MCP 使用该客户端已有的模型权限。

## 安装说明

### 一键安装（推荐）

需要你做的只有连接并解锁 iPhone、按提示登录账户，以及完成 iPhone 权限、本机连接和模型账号设置。

把下面这段发给 Claude Code、Codex 等智能体：

```text
从 https://github.com/JosssphZhou/poki 把 Poki 安装到我的 iPhone 上
```

智能体会按 [install-poki 技能](../skills/install-poki/SKILL.md)运行 `bin/install-iphone.mjs`，完成能自动处理的步骤。你只需处理 iOS 要求本人完成的操作：在 Mac 上的 Poki Setup 窗口输入 Apple 账户，在 iPhone 上点「信任」、开启开发者模式、信任开发者，然后打开 Poki。首次打开会请求开启自动化模式，点「继续」并输入 iPhone 密码即可。如果取消，重新开启 Poki 后会再次询问。每一步需要你操作时，智能体都会说明。免费 Apple 账户也能用。

当前安装器统一选择 Beta。历史 Stable、Alpha 和 Pre-alpha 偏好也会转为 Beta；没有可用 Beta 时停止。已安装的旧版 Poki Setup 可能仍按原通道选择，请以本次安装显示的版本为准。

没有 Node.js 24，或使用 Windows？装好 Poki Setup 后，同一段提示也能用，智能体会调用其内置命令行工具。Poki Setup 菜单也能复制安装提示，Mac 上位于 `Poki > Copy Prompt for Your Agent`，Windows 上位于 `Settings > Use an agent`。

如果安装器读取 GitHub 发布信息时遇到 403 或 429，通常是同一网络共用的匿名请求额度已耗尽。可以换网络或代理节点重试，也可以等一小时。

### 使用 Poki Setup 安装

从包含安装器的最新 [Beta 发布](https://github.com/JosssphZhou/poki/releases)下载 macOS 版 Poki Setup（`.dmg`）或 Windows 版（`.exe`，由 [ZhehanZhang](https://github.com/ZhehanZhang) 贡献），然后按窗口提示操作。详细步骤见 [Poki Setup](../desktop/README.md)。

### 运行第一个任务

安装器核对已安装版本，且你完成本机连接和模型账号设置后，打开 Poki 并发送：

```text
在备忘录中新建一条标题为"Poki Demo"的笔记，正文分三行写 Milk、Eggs、Coffee。完成后打开这条笔记，不修改已有笔记。
```

在备忘录中核对新笔记：标题应为"Poki Demo"，正文三行分别为 Milk、Eggs、Coffee。不能只凭聊天中的完成回复判断成功。如果没有备忘录应用或设置尚未完成，先处理对应步骤。中断后重试前，先检查笔记是否已经创建。

## 常见问题

**Windows 能安装吗？** 可以。Windows 版 Poki Setup 和 Mac 版一样支持安装、配对和续签。先安装 Apple Devices 或 iTunes，让电脑能识别 iPhone。详见 [Poki Setup](../desktop/README.md)。

**安装后还需要电脑吗？** 执行任务不需要，Poki 在 iPhone 上独立运行。免费 Apple 账户需要续签，可保持电脑上的 Poki Setup 运行，也可以在 Poki 内登录 Apple 账户，让 iPhone 自己续签。若登录失败，请改用电脑上的 Poki Setup。详见[哪些需要保持运行](../skills/install-poki/SKILL.md#what-to-keep-running)。

**免费 Apple 账户能用吗？7 天是什么意思？** 能用，但 Apple 为免费账户签发的应用签名只有 7 天有效期。Poki Setup 保持运行、电脑未睡眠且能连接 iPhone 时，会每 6 小时检查并为剩余有效期不超过 2 天的应用续签。未续签的应用到期后无法打开，Poki 会在最后 2 天提醒。详见[没有付费开发者账户](../skills/install-poki/SKILL.md#no-paid-developer-account)。

**需要哪款 iPhone 和哪个 iOS 版本？** iOS 18 或更高版本，即 iPhone XS、XR、SE（第 2 代）或更新机型，也支持安装到 iPadOS 18 或更高版本的 iPad。目前真机测试使用 iOS 27，iOS 18 至 26 的控制方式不同，尚未在真机验证。详见[验证记录与已知限制](verification.md)。

**需要自己的模型账户吗？** 需要。可用 ChatGPT Plus 或 Pro 登录，填写 Anthropic、OpenAI、Gemini、DeepSeek、OpenRouter 或 OpenCode Go 的 API 密钥，或接入自己的 OpenAI 兼容服务。语音对话还需要语音模型密钥。详见[需要准备什么](#需要准备什么)。

**看不到更新，例如在中国大陆的网络上，怎么办？** Poki 从 GitHub 检查更新，部分网络无法访问，或遇到 403、429 请求限制。可换网络或代理节点，也可以在电脑上的 Poki Setup 中使用 Renew 更新。详见[更新 Poki](#更新-poki)。

**Poki 会修改手机里的内容吗？操作前会询问吗？** Poki 会在真实应用里执行你的要求，包括发送消息，屏幕内容会发送到你配置的模型服务。付款、菜单和确认弹窗中的删除以及钱包中的操作始终需要确认。其他敏感步骤，例如发送消息或输入密码，可以在 `Settings > Approvals` 中选择询问方式，也可以选择不询问。详见[已知问题](#已知问题)。

## 更新 Poki

- **在 iPhone 上更新。** 打开 Poki 的签名与更新页面：当前版本位于 `Settings > Signing & Updates`。旧版本可能放在"连接"下面。有新构建时，页面会提供下载和安装。如果要求先登录，说明 Poki 从电脑安装，手机上还没有你的 Apple 账户。请使用安装时的账户登录，或改用电脑更新。
- **从电脑更新。** Poki Setup 中的 Renew 会将所选通道的最新构建安装到现有应用上。Mac 用户也可以告诉智能体「更新我 iPhone 上的 Poki」。install-poki 技能有独立的更新流程，会先核对已安装版本和签名身份。
- 如果更新停在「正在完成更新」，请在应用切换器中划掉 Poki，再重新打开并查看设置中的版本。版本未变化时，请用电脑上的 Poki Setup 更新。不要为了修复更新而删除 Poki，删除应用会一并删除对话。

发布通道以及构建从 Alpha 进入 Beta 的方式见[发布通道](release-channels.md)。

## 试跑一个任务

打开 Poki，在输入框里写下任务，例如「查一下明天的天气，告诉我需不需要带伞」，也可以点首页的应用来发起任务。Poki 会操作屏幕上的应用，在灵动岛和锁屏上显示每一步，并按你的设置征求许可。

你也可以不用打开 Poki：长按操作按钮与它交谈，或通过快捷指令和 Siri 调用 Talk to Poki、Send Task to Poki。这样发送的任务会通过通知回复。在 iPhone Duo 的分屏视图中，Poki 还能同时操作两个应用。

> **注意：** Poki 控制的是真实 iPhone。你让它发消息或付款，它就会执行。

## 已知问题

- Poki 操作的是真实 iPhone，会按要求发送消息或付款。屏幕内容会发送到你配置的模型服务。
- 如果无法在 iPhone 上登录 Apple 账户，请用电脑上的 Poki Setup 续签和更新。
- 真机支持目前只在中文界面、竖屏的 iPhone 上验证过，不支持横屏。
- 本版本尚未在低于 iOS 27 的 iPhone 真机或 iPad 上测试。较老或较小的 iPhone 运行立体小熊和首页动画时可能更热、更慢。低电量模式或减弱动态效果会改为显示静态小熊。
- 免费 Apple 账户的签名有效期为 7 天。请确保电脑上的 Poki Setup 能连接 iPhone，或在到期前手动续签。
- 从 GitHub 读取发布信息可能遇到 403 或 429，通常是多人共用网络所致。可换网络或代理节点重试，也可以等一小时。

更多限制和测试结果见[验证记录与已知限制](verification.md)。

## 路线图

这里只列方向，不承诺日期。已发布功能见 [CHANGELOG.md](../CHANGELOG.md)。

**Released in 0.4 Beta**

- iPhone App 在设置完成后无需电脑即可执行任务，锁屏和灵动岛支持审批。
- 使用免费 Apple 账户，通过 Mac 或 Windows 上的智能体或 Poki Setup 安装。
- iOS 27 及以上的原生控制，以及 Poki 内置浏览器中的网页任务。
- 立体小熊新首页、语音对话、操作按钮、对话归档、iPhone Duo 分屏视图、可调整界面大小和深色模式。

**In progress**

- 更可靠的更新下载和统一的更新处理。
- 更多界面语言。

**Planned**

- 在真机上验证更多 iPhone、iOS 版本和屏幕语言。
- 支持更多模型提供商。

## 其他工具

[Poki MCP](poki-mcp.md) 将电脑上的智能体连接到 iPhone 或 iOS 模拟器，这个早期工具已停止更新。

[Poki Agent](poki-mcp.md#try-a-task-with-poki-agent) 是支持 iMessage 和 Telegram 渠道的终端智能体，安装和使用方式见链接中的指南。

## 免责声明

Poki 是独立的开源项目，与 Apple、OpenAI 以及它所操作的任何应用或网站的开发者均无关联，也未获得其认可。iPhone 是 Apple Inc. 的商标。

自动操作第三方应用和网站可能违反其服务条款，请自行判断是否在相应服务上使用 Poki。Poki 在你的设备和账号上执行的操作由你负责，包括它发送的消息、作出的更改，以及由此导致的账号限制。

Poki 按「原样」提供，不附带任何担保，具体以 AGPL-3.0 许可证为准。

## 开源许可

Poki 的代码基于 [AGPL-3.0-only 许可证](../LICENSE)开源。

Poki 小熊、应用图标和 Poki 的其他美术作品不在这一许可证范围内。你可以用截图介绍 Poki；分叉版本需要使用自己的名称和美术。详见 [BRAND.md](../BRAND.md)。

Copyright (c) 2026 Joseph Zhou (周瑟夫) and contributors. 开源依赖项和第三方素材保留各自的许可证，详见 [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md)。如需参与贡献，请阅读 [CONTRIBUTING.md](../CONTRIBUTING.md)。
