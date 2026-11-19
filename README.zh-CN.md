<p align="center">
  <a href="https://poki.bot"><img src="docs/images/poki-hero.zh-CN.gif" width="100%" alt="Poki 像你一样使用你的 iPhone：在真机上替你点按、打字、滑动的智能体"></a>
</p>

<h3 align="center">复制这段话，发给你的编码智能体</h3>

```text
从 https://github.com/JosssphZhou/poki 把 Poki 安装到我的 iPhone 上
```

<p align="center"><sub>先用 USB 数据线连接并解锁 iPhone，免费 Apple 账户即可。</sub></p>

<!-- badges:start -->
<p align="center">
  <a href="https://github.com/JosssphZhou/poki/stargazers"><img src="https://img.shields.io/github/stars/JosssphZhou/poki" alt="GitHub stars"></a>
  <a href="https://github.com/JosssphZhou/poki/releases"><img src="https://img.shields.io/badge/Poki_App-0.4.4_Beta-blue" alt="Poki App 0.4.4 Beta"></a>
  <img src="https://img.shields.io/badge/platform-iOS%20%7C%20macOS%20%7C%20Windows-lightgrey" alt="Platform: iOS, macOS and Windows">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-AGPL--3.0--only-blue" alt="License: AGPL-3.0-only"></a>
</p>
<!-- badges:end -->

<p align="center">
  <a href="README.md">English</a> | 简体中文 | <a href="README.zh-TW.md">繁體中文</a> | <a href="README.ja.md">日本語</a> | <a href="README.ko.md">한국어</a> | <a href="README.es.md">Español</a><br>
  <a href="https://poki.bot">poki.bot</a>
</p>

<p align="center">
  <strong>如果 Poki 对你有帮助，请点击 ★ Star 支持这个项目。</strong>
</p>

## Poki 是什么

Poki 是开源的 iPhone agent，能替你操作整台 iPhone。Poki 应用直接运行在你的 iPhone 上，会读取屏幕，并在真实应用中点击、输入和滚动，使用你自己的模型账户。你可以选择它如何征求许可；付款、删除和钱包中的操作始终需要你的确认。

<p align="center">
  <img src="docs/images/poki-order-demo.gif" width="280" alt="Poki 自己在 Uber Eats 上点餐">
</p>

## 为什么用 Poki

<p align="center">
  <img src="docs/images/why-1-errands.gif" width="32%" alt="Poki 在聊天中接收点餐指令，并在 Uber Eats 中将菜品加入购物车">
  <img src="docs/images/why-2-routines.gif" width="32%" alt="Poki 在真实的 Uber 应用中预约乘车">
  <img src="docs/images/why-3-standalone.gif" width="32%" alt="Poki 回复上车地点与预估车费">
</p>

- **日常杂事不必跨多个应用来回点按。** 直接在对话里交代 Poki，或长按操作按钮、呼叫 Siri，就能用内置浏览器查资料、看明天天气或新建备忘录。在 iPhone Duo 上，Poki 还能在分屏视图中同时操作两个应用。
- **重复任务点一下或说一句话就跑完。** 不用每天重复同样的步骤，直接在首页点击保存的技能，或用「和 Poki 对话」语音沟通，每一步进展都会显示在灵动岛上。
- **不依赖电脑持续开机，直接操作真机。** 通过 Mac 或 Windows 电脑完成一次安装后，Poki 即可在 iPhone 上独立运行，遇到付款、删除或钱包操作时在锁屏或灵动岛暂停等待你的确认。

## 怎么用

### 在 iPhone 上安装 Poki

1. **通过 Mac 或 Windows 电脑完成一次安装。** 用 USB 数据线连接并解锁 iPhone（免费 Apple 账户即可），然后把下面这段话发给你的编码智能体（如 Claude Code 或 Codex）：

   ```text
   从 https://github.com/JosssphZhou/poki 把 Poki 安装到我的 iPhone 上
   ```

   也可以从 [GitHub Releases](https://github.com/JosssphZhou/poki/releases) 下载 macOS 版（`.dmg`）或 Windows 版（`.exe`）Poki Setup，按窗口提示操作。
2. **完成连接并配置模型账户。** 按 iOS 提示点「信任」、开启开发者模式和自动化模式，配置将 `10.7.0.1` 路由回本机的外部代理通道（如免费的 LocalDevVPN），再用 ChatGPT Plus 或 Pro 登录，或填入 Anthropic、OpenAI、Gemini、DeepSeek、OpenRouter、OpenCode Go 的 API 密钥，或接入 OpenAI 兼容服务。
3. **试跑第一个任务。** 打开 Poki 并发送：

   ```text
   在备忘录中新建一条标题为“Poki Demo”的笔记，正文分三行写 Milk、Eggs、Coffee。完成后打开这条笔记，不修改已有笔记。
   ```

   完成后打开备忘录，确认标题为“Poki Demo”且正文包含这三行内容。

<details>
<summary>环境要求、更新方法、常见问题与文档索引</summary>

| 项目 | 要求 |
| --- | --- |
| iPhone | iOS 18 或更高版本（iPhone XS、XR、SE 第 2 代及更新机型；也支持 iPadOS 18+）。真机已在 iOS 27 上测试。 |
| 电脑 | macOS 14+ 的 Mac（智能体安装需要 Node.js 24+），或已安装 Apple Devices 或 iTunes 的 Windows 电脑（x64）。 |
| 数据线与账户 | USB 数据线与 Apple 账户。电脑打开 Poki Setup 时可自动续签免费 7 天签名，也可在 Poki 内登录续签。 |
| 连接 | 将 `10.7.0.1` 路由回 iPhone 的外部代理通道（LocalDevVPN、Karing 或 Shadowrocket）。 |
| 模型账户 | ChatGPT Plus/Pro 登录、API 密钥（Anthropic、OpenAI、Gemini、DeepSeek、OpenRouter、OpenCode Go）或 OpenAI 兼容服务。 |

- 智能体安装技能与桌面助手：[install-poki 技能](skills/install-poki/SKILL.md) 与 [Poki Setup](desktop/README.md)
- 测试验证、平台限制与发布通道：[验证与限制](docs/verification.md) 与 [发布通道](docs/release-channels.md)
- 早期电脑端连接工具（已停止更新）：[Poki MCP 与 Poki Agent](docs/poki-mcp.md)

</details>

- 完整安装细节、更新、常见问题、已知限制与路线图：[Poki iPhone 使用指南](docs/iphone-guide.zh-CN.md)
- 版本变更记录：[CHANGELOG.md](CHANGELOG.md)

## 社区

- **提问与交流：** 欢迎加入 [GitHub Discussions](https://github.com/JosssphZhou/poki/discussions)。
- **缺陷反馈与建议：** 请在 [GitHub Issues](https://github.com/JosssphZhou/poki/issues) 提交问题。
- **参与贡献：** 请先阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。

查看所有贡献者：[CONTRIBUTING.md](CONTRIBUTING.md#contributors)。

<br>

<p align="center"><img src="docs/images/poki-icon.png" width="40" height="40" alt="Poki"></p>

<p align="center"><sub>Copyright (c) 2026 Joseph Zhou (周瑟夫) and contributors. 基于 <a href="LICENSE">AGPL-3.0-only</a> 开源。品牌素材受 <a href="BRAND.md">BRAND.md</a> 约束。详见 <a href="docs/iphone-guide.zh-CN.md">Poki iPhone 使用指南</a>、<a href="THIRD_PARTY_NOTICES.md">THIRD_PARTY_NOTICES.md</a> 与 <a href="docs/iphone-guide.zh-CN.md#免责声明">免责声明</a>。</sub></p>
