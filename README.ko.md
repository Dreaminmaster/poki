<p align="center">
  <img src="docs/images/poki-icon.png" width="72" height="72" alt="Poki icon">
</p>

<h1 align="center">Poki는 당신의 iPhone을 당신처럼 씁니다</h1>

<p align="center">
  <img src="docs/images/poki-home.gif" width="720" alt="Poki 공식 웹사이트 홈페이지 애니메이션">
</p>

<p align="center">
  <a href="README.md">English</a> | <a href="README.zh-CN.md">简体中文</a> | <a href="README.zh-TW.md">繁體中文</a> | <a href="README.ja.md">日本語</a> | 한국어 | <a href="README.es.md">Español</a><br>
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

Poki는 iPhone을 조작하는 앱입니다. 화면을 읽고 실제 앱에서 탭, 입력, 스크롤을 수행합니다. 승인을 요청하는 방식은 선택할 수 있지만, 결제와 삭제, Wallet에서의 작업은 항상 확인을 받습니다.

**Poki 앱**은 iPhone 자체에서 실행됩니다. 채팅으로 작업을 부탁하면 다른 앱에서 수행합니다. Mac이나 Windows PC에서 한 번 설치하면 이후 작업은 컴퓨터 없이 iPhone에서 실행됩니다.

버전별 변경 사항은 [CHANGELOG.md](CHANGELOG.md)를 확인하세요.

## iPhone에 Poki 설치하기

처음 설치할 때 Mac 또는 Windows PC가 필요합니다.

- **Mac에서는** 에이전트에게 설치를 맡기거나 macOS용 Poki Setup을 내려받아 창의 안내를 따르세요.
- **Windows에서는** Windows용 Poki Setup을 내려받아 안내를 따르세요. USB로 iPhone을 인식할 수 있도록 Apple Devices 또는 iTunes를 먼저 설치하세요. 에이전트가 Poki Setup에 포함된 명령줄 도구를 사용할 수도 있습니다.
- **설치 후에는** 컴퓨터 없이 iPhone에서 작업을 실행합니다. 무료 Apple 계정의 서명은 7일간 유효하며, 컴퓨터에서 Poki Setup을 계속 실행하면 갱신할 수 있습니다. [자주 묻는 질문](#자주-묻는-질문)을 참고하세요.

### 에이전트로 설치하기 (권장)

Claude Code나 Codex 같은 에이전트에게 다음과 같이 요청하세요.

```text
https://github.com/JosssphZhou/poki 에서 내 iPhone에 Poki를 설치해 줘
```

에이전트는 [install-poki 스킬](skills/install-poki/SKILL.md)에 따라 `bin/install-iphone.mjs`를 실행해 자동화할 수 있는 단계를 처리합니다. 사용자는 Mac의 Poki Setup 창에서 Apple 계정 입력, iPhone에서 신뢰 선택, 개발자 모드 활성화, 개발자 신뢰, Poki 실행을 직접 합니다. 처음 열 때 자동화 모드를 요청하면 계속을 누르고 iPhone 암호를 입력하세요. 취소했다면 Poki를 다시 켜면 요청이 다시 표시됩니다. 직접 해야 할 단계마다 에이전트가 안내합니다. 무료 Apple 계정도 사용할 수 있습니다.

설치 프로그램은 기본적으로 Alpha 채널을 사용합니다. Beta 등 다른 채널을 원하면 에이전트에게 알려 주세요. 빌드는 Alpha에 먼저 공개되며, 추가 테스트를 거친 뒤 같은 빌드가 Beta로 이동합니다.

Node.js 24가 없거나 Windows를 사용하나요? Poki Setup을 설치하면 같은 요청을 사용할 수 있습니다. 에이전트가 내장 명령줄 도구를 사용합니다. Poki Setup 메뉴에서도 요청문을 복사할 수 있습니다. Mac은 Poki > Copy Prompt for Your Agent, Windows는 Settings > Use an agent입니다.

설치 프로그램이 릴리스 정보를 읽다가 GitHub에서 403 또는 429를 받으면, 같은 네트워크에서 공유하는 시간당 익명 요청 한도에 도달한 경우가 많습니다. 다른 네트워크나 프록시 서버로 다시 시도하거나 한 시간 기다리세요.

### Poki Setup으로 설치하기

직접 설치하려면 [Alpha 릴리스](https://github.com/JosssphZhou/poki/releases/tag/app-alpha-latest)에서 macOS용 Poki Setup(`.dmg`) 또는 Windows용(`.exe`, [ZhehanZhang](https://github.com/ZhehanZhang) 기여)을 내려받아 안내를 따르세요. Beta 릴리스에도 같은 Poki Setup 파일이 있습니다. 설정에서 채널을 선택하기 전에는 최신 Stable을 설치하고, Stable이 없으면 Beta를 설치합니다. 단계별 설명은 [Poki Setup](desktop/README.md)을 참고하세요.

### 준비할 것

| 항목 | 요구 사항 |
| --- | --- |
| iPhone | iOS 18 이상인 iPhone XS, XR, SE(2세대) 또는 이후 기종. 실제 기기 테스트는 iOS 27이 설치된 iPhone에서 진행했습니다. |
| 컴퓨터 | macOS 14 이상인 Mac, 또는 Apple Devices나 iTunes가 설치된 Windows PC(x64). Mac에서 에이전트가 설치 스크립트를 사용하려면 Node.js 24 이상도 필요합니다. |
| 케이블과 계정 | USB 데이터 케이블과 Apple 계정. 무료 계정의 서명은 7일간 유효하며 Poki Setup이 갱신할 수 있습니다. |
| 연결 | 10.7.0.1을 iPhone 자체로 연결하는 VPN 앱. App Store의 무료 LocalDevVPN이나 Poki의 안내에 따라 설정한 Karing, Shadowrocket을 사용할 수 있습니다. |
| 모델 계정 | 본인 계정이 필요합니다. ChatGPT Plus 또는 Pro 로그인이 간편한 시작 방법입니다. Anthropic, OpenAI, Gemini, DeepSeek, OpenRouter의 API 키나 자체 OpenAI 호환 서버도 사용할 수 있습니다. Claude 구독으로는 로그인할 수 없으므로 Anthropic API 키를 사용하세요. |

iOS 27 이상에서는 네이티브 서비스로 iPhone을 조작합니다. iOS 18부터 26까지는 XCTest 세션을 사용하므로 iPhone 개발자 설정에서 UI 자동화를 켜야 합니다. iPadOS 18 이상인 iPad에도 설치할 수 있습니다.

### 자주 묻는 질문

**Windows에서도 설치할 수 있나요?** 네. Windows용 Poki Setup은 Mac 버전처럼 설치, 페어링, 서명 갱신을 지원합니다. PC가 iPhone을 인식하도록 Apple Devices 또는 iTunes를 먼저 설치하세요. [Poki Setup](desktop/README.md)을 참고하세요.

**설치 후에도 컴퓨터가 필요한가요?** 작업 실행에는 필요하지 않습니다. Poki는 iPhone에서 독립적으로 작동합니다. 무료 Apple 계정이라면 컴퓨터에서 Poki Setup을 계속 실행해 서명을 갱신하거나, Poki에서 Apple 계정에 로그인해 iPhone이 직접 갱신하도록 할 수 있습니다. 로그인이 실패하면 컴퓨터의 Poki Setup을 사용하세요. [계속 실행해 둘 항목](skills/install-poki/SKILL.md#what-to-keep-running)을 참고하세요.

**무료 Apple 계정도 되나요? 7일 제한은 무엇인가요?** 사용할 수 있지만 Apple이 발급하는 서명은 7일간만 유효합니다. Poki Setup이 실행 중이고 컴퓨터가 깨어 있으며 iPhone에 연결할 수 있으면, 6시간마다 확인해 유효 기간이 2일 이하인 앱의 서명을 갱신합니다. 갱신하지 않으면 만료 후 앱을 열 수 없으므로 Poki가 마지막 2일 동안 알려 줍니다. [유료 개발자 계정이 없는 경우](skills/install-poki/SKILL.md#no-paid-developer-account)를 참고하세요.

**어떤 iPhone과 iOS가 필요한가요?** iOS 18 이상인 iPhone XS, XR, SE(2세대) 또는 이후 기종이며, iPadOS 18 이상인 iPad에도 설치할 수 있습니다. 실제 기기 테스트는 iOS 27에서 진행했습니다. 다른 제어 방식을 사용하는 iOS 18부터 26까지는 실제 iPhone에서 아직 검증하지 않았습니다. [검증 결과와 알려진 제한](docs/verification.md)을 참고하세요.

**내 모델 계정이 필요한가요?** 네. ChatGPT Plus 또는 Pro로 로그인하거나 Anthropic, OpenAI, Gemini, DeepSeek, OpenRouter의 API 키 또는 자체 OpenAI 호환 서버를 사용하세요. 음성 대화에는 음성 모델 키도 필요합니다. [준비할 것](#준비할-것)을 참고하세요.

**중국 본토 네트워크 등에서 업데이트가 보이지 않으면 어떻게 하나요?** Poki는 GitHub에서 업데이트를 확인합니다. 일부 네트워크는 접속할 수 없거나 403, 429 요청 제한에 걸립니다. 다른 네트워크나 프록시 서버를 사용하거나, 컴퓨터의 Poki Setup에서 Renew로 업데이트하세요. [Poki 업데이트하기](#poki-업데이트하기)를 참고하세요.

**내 iPhone의 내용을 변경하나요? 먼저 물어보나요?** 실제 앱에서 메시지 전송 등 요청한 작업을 수행하며, 화면 내용은 설정한 모델 서비스로 전송됩니다. 결제와 삭제, Wallet 작업은 항상 확인을 받습니다. 메시지 전송이나 암호 입력 같은 다른 민감한 단계는 설정 > 승인에서 확인 방법이나 확인 여부를 선택할 수 있습니다. [알려진 문제](#알려진-문제)를 참고하세요.

## Poki 업데이트하기

- **iPhone에서 업데이트.** 0.4.0에서는 설정 > 연결 > 서명 및 업데이트를 여세요. 새 빌드가 있으면 다운로드하고 설치할 수 있습니다. 먼저 로그인을 요청한다면 컴퓨터에서 설치했기 때문에 iPhone에 Apple 계정이 아직 없는 상태입니다. 설치할 때 쓴 계정으로 로그인하거나 컴퓨터에서 업데이트하세요.
- **컴퓨터에서 업데이트.** Poki Setup의 Renew는 선택한 채널의 최신 빌드를 기존 앱 위에 설치합니다. Mac에서는 에이전트에게 “내 iPhone의 Poki를 업데이트해 줘”라고 요청할 수도 있습니다. install-poki 스킬은 설치된 버전과 서명 정보를 먼저 확인하는 별도 업데이트 절차를 제공합니다.
- 업데이트가 “Finishing the update”에서 멈추면 앱 전환기에서 Poki를 종료한 뒤 다시 열고 설정에서 버전을 확인하세요. 버전이 바뀌지 않았다면 컴퓨터의 Poki Setup으로 업데이트하세요. 업데이트 문제를 해결하려고 Poki를 삭제하지 마세요. 대화도 함께 삭제됩니다.

채널과 Alpha에서 Beta로 빌드가 이동하는 절차는 [릴리스 채널](docs/release-channels.md)을 참고하세요.

## 알려진 문제

- Poki는 실제 iPhone을 조작하며 요청한 메시지 전송이나 결제를 실행합니다. 화면 내용은 설정한 모델 서비스로 전송됩니다.
- iPhone에서 Apple 계정에 로그인할 수 없으면 컴퓨터의 Poki Setup으로 서명을 갱신하고 앱을 업데이트하세요.
- 실제 기기 지원은 중국어 인터페이스와 세로 방향의 iPhone에서만 검증했습니다. 가로 방향은 지원하지 않습니다.
- 이 릴리스는 iOS 27 미만의 실제 iPhone이나 iPad에서 테스트하지 않았습니다. 오래되거나 작은 iPhone에서는 입체 곰과 홈 화면 애니메이션으로 발열이나 지연이 생길 수 있습니다. 저전력 모드나 동작 줄이기를 켜면 곰을 정지 이미지로 표시합니다.
- 무료 Apple 계정의 서명은 7일간 유효합니다. 컴퓨터의 Poki Setup이 iPhone에 연결할 수 있도록 유지하거나 만료 전에 수동 갱신하세요.
- GitHub 릴리스 조회가 403 또는 429로 실패할 수 있으며, 여러 사람이 네트워크를 공유할 때 흔히 발생합니다. 네트워크나 프록시 서버를 바꾸거나 한 시간 기다리세요.

더 많은 제한과 테스트 결과는 [검증 결과와 알려진 제한](docs/verification.md)을 참고하세요.

## 작업 실행해 보기

Poki를 열고 “내일 날씨를 확인해서 우산이 필요한지 알려 줘” 같은 작업을 입력하거나 홈 화면에서 앱을 눌러 시작하세요. Poki가 화면의 앱을 조작하고 Dynamic Island와 잠금 화면에 각 단계를 표시하며 설정에 따라 승인을 요청합니다.

Poki를 열지 않고 부를 수도 있습니다. 동작 버튼을 길게 눌러 대화하거나 단축어와 Siri에서 Talk to Poki 또는 Send Task to Poki를 사용하세요. 이 방식으로 보낸 작업의 결과는 알림으로 도착합니다.

> **참고:** Poki는 실제 iPhone을 제어합니다. 메시지 전송이나 결제를 요청하면 실행합니다.

## 로드맵

날짜를 약속하는 일정이 아니라 앞으로의 방향입니다. 출시된 기능은 [CHANGELOG.md](CHANGELOG.md)에 기록되어 있습니다.

**0.4.0 Beta에 출시됨**

- 설정 후 컴퓨터 없이 작업을 실행하는 iPhone 앱과 잠금 화면 및 Dynamic Island에서의 승인.
- 무료 Apple 계정으로 Mac 또는 Windows의 에이전트나 Poki Setup을 통한 설치.
- iOS 27 이상의 네이티브 제어와 Poki 내장 브라우저에서의 웹 작업.
- 입체 곰이 있는 새 홈 화면, 음성 대화, 동작 버튼, 대화 보관, 다크 모드.

**진행 중**

- 업데이트 다운로드를 더 안정적인 서버로 옮기고 GitHub는 예비 경로로 유지.
- 여러 업데이트 채널을 하나로 통합.
- 더 많은 인터페이스 언어.

**계획됨**

- 더 많은 iPhone, iOS 버전, 화면 언어를 실제 기기에서 검증.
- 더 많은 모델 제공업체 지원.

## 문서

| 주제 | 문서 |
| --- | --- |
| 버전별 변경 사항 | [CHANGELOG.md](CHANGELOG.md) |
| 에이전트로 iPhone 앱 설치 | [install-poki 스킬](skills/install-poki/SKILL.md) |
| Mac 및 Windows용 Poki Setup | [Poki Setup](desktop/README.md) |
| 릴리스 채널과 버전 승격 | [릴리스 채널](docs/release-channels.md) |
| 테스트 결과, 알려진 제한, 면책 사항 | [검증](docs/verification.md) |
| 로드맵 | [로드맵](#로드맵) |

## Star History

<a href="https://www.star-history.com/?repos=JosssphZhou%2Fpoki&type=date&legend=top-left">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=JosssphZhou/poki&type=date&theme=dark&legend=top-left">
    <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=JosssphZhou/poki&type=date&legend=top-left">
    <img alt="Star History chart" src="https://api.star-history.com/chart?repos=JosssphZhou/poki&type=date&legend=top-left">
  </picture>
</a>

## 공동 창작자

<!-- CO-CREATOR:START -->
<p align="center">
  <a href="https://github.com/ZhehanZhang"><img src="https://avatars.githubusercontent.com/u/67270559?v=4&size=320" width="160" height="160" alt="ZhehanZhang"/><br /><b>ZhehanZhang</b></a><br />
  Poki의 위대한 공동 창작자.
</p>
<!-- CO-CREATOR:END -->

## 핵심 기여자

<!-- CORE-CONTRIBUTORS:START -->
<table>
  <tbody>
    <tr>
      <td align="center" valign="top" width="33%"><a href="https://github.com/makirqi-alt"><img src="https://avatars.githubusercontent.com/u/295395617?v=4&size=240" width="120" height="120" alt="makirqi-alt"/><br /><sub><b>makirqi-alt</b></sub></a><br />Poki의 첫 번째 이슈 <a href="https://github.com/JosssphZhou/poki/issues/1">#1</a>을 올렸습니다. iOS 18.6.2에서 스크린샷은 되고 손쉬운 사용과 터치는 안 된다는 점을 명확히 나누어 적어 주었습니다.</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/edge369"><img src="https://avatars.githubusercontent.com/u/63720633?v=4&size=240" width="120" height="120" alt="edge369"/><br /><sub><b>edge369</b></sub></a><br /><a href="https://github.com/JosssphZhou/poki/pull/14">#14</a>에서 Poki를 라우터에서 실행할 수 있게 만들어 Mac이 꺼져 있어도 Telegram으로 iPhone을 조작할 수 있게 했고, <a href="https://github.com/JosssphZhou/poki/pull/15">#15</a>, <a href="https://github.com/JosssphZhou/poki/pull/17">#17</a>, <a href="https://github.com/JosssphZhou/poki/issues/19">#19</a>가 이어졌습니다.</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/mawenhao1028"><img src="https://avatars.githubusercontent.com/u/70818670?v=4&size=240" width="120" height="120" alt="mawenhao1028"/><br /><sub><b>mawenhao1028</b></sub></a><br /><a href="https://github.com/JosssphZhou/poki/issues/6">#6</a>에서 macOS 27.2의 usbmuxd가 iPhone을 목록에 보이지 않는 문제를 보고했습니다. 이제 Poki는 이를 분명히 알리고 도우미가 일찍 멈춘 이유도 알려 줍니다(<a href="https://github.com/JosssphZhou/poki/issues/59">#59</a>).</td>
    </tr>
    <tr>
      <td align="center" valign="top" width="33%"><a href="https://github.com/igc110"><img src="https://avatars.githubusercontent.com/u/241411380?v=4&size=240" width="120" height="120" alt="igc110"/><br /><sub><b>igc110</b></sub></a><br /><a href="https://github.com/JosssphZhou/poki/issues/10">#10</a>에서 실제 iPhone의 탭이 느린 원인을 찾아냈고, 이후 수정으로 탭이 약 3분의 1 빨라졌습니다.</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/carrotciallo"><img src="https://avatars.githubusercontent.com/u/69567867?v=4&size=240" width="120" height="120" alt="carrotciallo"/><br /><sub><b>carrotciallo</b></sub></a><br /><a href="https://github.com/JosssphZhou/poki/issues/16">#16</a>에서 Poki를 Linux로 포팅해 실제 iPhone에서 USB, LAN, Tailscale 연결을 검증했고, README는 이 포팅 버전을 안내합니다.</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/guangtouge82"><img src="https://avatars.githubusercontent.com/u/269691899?v=4&size=240" width="120" height="120" alt="guangtouge82"/><br /><sub><b>guangtouge82</b></sub></a><br /><a href="https://github.com/JosssphZhou/poki/issues/18">#18</a>에서 실제 iPhone의 터치 실패 원인이 display service 누락임을 밝혀냈고, 이제 Poki는 아무것도 전송되지 않았다고 알리며 prepare-device를 안내합니다.</td>
    </tr>
    <tr>
      <td align="center" valign="top" width="33%"><a href="https://github.com/Dreaminmaster"><img src="https://avatars.githubusercontent.com/u/189544503?v=4&size=240" width="120" height="120" alt="Dreaminmaster"/><br /><sub><b>Dreaminmaster</b></sub></a><br />손상된 캐시 경로가 관련 없는 Agent 작업을 중단시키는 문제를 고쳤고(<a href="https://github.com/JosssphZhou/poki/issues/21">#21</a>, <a href="https://github.com/JosssphZhou/poki/pull/22">#22</a>), 이어 <a href="https://github.com/JosssphZhou/poki/pull/37">#37</a>에서 Agent가 동작 후 읽은 화면을 재사용하게 했습니다.</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/PeterKingXu1s"><img src="https://avatars.githubusercontent.com/u/89392314?v=4&size=240" width="120" height="120" alt="PeterKingXu1s"/><br /><sub><b>PeterKingXu1s</b></sub></a><br /><a href="https://github.com/JosssphZhou/poki/issues/25">#25</a>에서 자연어 중지 요청으로는 iMessage 작업이 멈추지 않는다고 보고했고, 이제 Poki는 작업 도중 받은 메시지에 답하며 /stop을 안내합니다.</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/ScottH1122"><img src="https://avatars.githubusercontent.com/u/142722955?v=4&size=240" width="120" height="120" alt="ScottH1122"/><br /><sub><b>ScottH1122</b></sub></a><br /><a href="https://github.com/JosssphZhou/poki/issues/27">#27</a>과 <a href="https://github.com/JosssphZhou/poki/issues/28">#28</a>에서 Agent 버그 두 건을 재현한 뒤, 취소된 입력 잠금(<a href="https://github.com/JosssphZhou/poki/pull/102">#102</a>)부터 잘못된 터치 좌표(<a href="https://github.com/JosssphZhou/poki/pull/136">#136</a>)까지 수정과 테스트 정비 일곱 건을 병합했습니다.</td>
    </tr>
    <tr>
      <td align="center" valign="top" width="33%"><a href="https://github.com/jiahuipaung"><img src="https://avatars.githubusercontent.com/u/70688286?v=4&size=240" width="120" height="120" alt="jiahuipaung"/><br /><sub><b>jiahuipaung</b></sub></a><br />iPhone의 LAN 주소가 바뀌면 끊기던 RemotePairing 연결(<a href="https://github.com/JosssphZhou/poki/issues/30">#30</a>)을 <a href="https://github.com/JosssphZhou/poki/pull/34">#34</a>에서 고쳤고, 실제 iPhone은 768ms 만에 다시 연결되었습니다.</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/Zeno6898"><img src="https://avatars.githubusercontent.com/u/229920081?v=4&size=240" width="120" height="120" alt="Zeno6898"/><br /><sub><b>Zeno6898</b></sub></a><br /><a href="https://github.com/JosssphZhou/poki/issues/35">#35</a>와 <a href="https://github.com/JosssphZhou/poki/issues/40">#40</a>에서 모바일 데이터와 Windows로 iPhone 앱을 실기기 테스트했고, 첫 설정에 Wi-Fi가 필요하다는 안내(<a href="https://github.com/JosssphZhou/poki/issues/138">#138</a>)로 이어졌습니다. <a href="https://github.com/JosssphZhou/poki/issues/162">#162</a>도 보고했습니다.</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/scy7796"><img src="https://avatars.githubusercontent.com/u/282529358?v=4&size=240" width="120" height="120" alt="scy7796"/><br /><sub><b>scy7796</b></sub></a><br />Windows 호스트에서 RemotePairing으로 연결할 때 탭이 매번 실패하던 문제를 <a href="https://github.com/JosssphZhou/poki/pull/39">#39</a>에서 고쳤고, 수정 후 5번 중 5번의 탭이 성공했습니다.</td>
    </tr>
    <tr>
      <td align="center" valign="top" width="33%"><a href="https://github.com/foshanfm"><img src="https://avatars.githubusercontent.com/u/24779370?v=4&size=240" width="120" height="120" alt="foshanfm"/><br /><sub><b>foshanfm</b></sub></a><br /><a href="https://github.com/JosssphZhou/poki/issues/42">#42</a>에서 Tailscale로 연결한 실제 iPhone으로 보험 약관을 확인했고, 이 보고가 더 알기 쉬운 USB 오류와 세션별 연결 방식 전환 작업으로 이어졌습니다.</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/xiaweiyi713"><img src="https://avatars.githubusercontent.com/u/208608622?v=4&size=240" width="120" height="120" alt="xiaweiyi713"/><br /><sub><b>xiaweiyi713</b></sub></a><br />Poki가 실제 iPhone을 조작하는 데모 영상을 제작해, 새 방문자가 설치하기 전에 무엇을 할 수 있는지 볼 수 있게 했습니다.</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/fucknima"><img src="https://avatars.githubusercontent.com/u/18666223?v=4&size=240" width="120" height="120" alt="f&#42;&#42;&#42;&#42;&#42;&#42;&#42;"/><br /><sub><b>f&#42;&#42;&#42;&#42;&#42;&#42;&#42;</b></sub></a><br /><a href="https://github.com/JosssphZhou/poki/pull/68">#68</a>에서 OpenCode Go를 iPhone 앱의 모델 계정으로 추가했습니다. 전용 키체인 자격 증명과 독립된 모델 선택을 갖추고 있습니다.</td>
    </tr>
    <tr>
      <td align="center" valign="top" width="33%"><a href="https://github.com/owensn951954688"><img src="https://avatars.githubusercontent.com/u/312761798?v=4&size=240" width="120" height="120" alt="owensn951954688"/><br /><sub><b>owensn951954688</b></sub></a><br /><a href="https://github.com/JosssphZhou/poki/issues/69">#69</a>에서 Runner가 약 25분 유휴 후 페어링에 실패하는 과정을 상세히 기록했습니다. 이제 Setup은 Loopback과 Pairing 확인을 안내합니다(<a href="https://github.com/JosssphZhou/poki/issues/70">#70</a>).</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/kira-ariaki"><img src="https://avatars.githubusercontent.com/u/257352493?v=4&size=240" width="120" height="120" alt="kira-ariaki"/><br /><sub><b>kira-ariaki</b></sub></a><br />배치 호출이 기기가 모호할 때 충돌하지 않고 알려 주도록 했고(<a href="https://github.com/JosssphZhou/poki/pull/74">#74</a>), POKI_MCP_DEVICE(<a href="https://github.com/JosssphZhou/poki/pull/75">#75</a>)와 작업별 선택적 승인 단계(<a href="https://github.com/JosssphZhou/poki/pull/77">#77</a>)를 추가했습니다.</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/Purelite"><img src="https://avatars.githubusercontent.com/u/9334469?v=4&size=240" width="120" height="120" alt="Purelite"/><br /><sub><b>Purelite</b></sub></a><br />페어링 설정이 잘못된 설정 페이지로 안내하던 문제를 고쳐, 개발자 모드와 UI 자동화 단계가 이제 올바른 페이지를 엽니다(<a href="https://github.com/JosssphZhou/poki/pull/137">#137</a>).</td>
    </tr>
    <tr>
      <td align="center" valign="top" width="33%"><a href="https://github.com/heyallencao"><img src="https://avatars.githubusercontent.com/u/258265534?v=4&size=240" width="120" height="120" alt="heyallencao"/><br /><sub><b>heyallencao</b></sub></a><br /><a href="https://github.com/JosssphZhou/poki/pull/139">#139</a>에서 화면 읽기가 호출 기한을 넘기던 문제를 고쳤고, 계속 느린 Runner 응답에 대한 회귀 테스트도 추가했습니다.</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/whiteluw"><img src="https://avatars.githubusercontent.com/u/86720151?v=4&size=240" width="120" height="120" alt="whiteluw"/><br /><sub><b>whiteluw</b></sub></a><br /><a href="https://github.com/JosssphZhou/poki/pull/326">#326</a>에서 iPhone의 3D 곰 초기화 중 발생하는 충돌을 수정했습니다.</td>
    </tr>
  </tbody>
</table>
<!-- CORE-CONTRIBUTORS:END -->

## 특별 기여자

<table>
  <tbody>
    <tr>
      <td align="center" valign="top" width="33%"><a href="https://github.com/yulunRyanw"><img src="https://avatars.githubusercontent.com/u/216360668?v=4&size=240" width="120" height="120" alt="yulunRyanw"/><br /><sub><b>yulunRyanw</b></sub></a><br />0.4.0 개편을 위해 채팅, 실시간 현황, 설정, 첫 실행 과정을 포함한 전체 인터페이스 디자인을 제공했습니다(<a href="https://github.com/JosssphZhou/poki/pull/250">#250</a>, <a href="https://github.com/JosssphZhou/poki/pull/256">#256</a>, <a href="https://github.com/JosssphZhou/poki/pull/268">#268</a>). 새 인터페이스의 방향을 잡는 데 기여했습니다.</td>
    </tr>
  </tbody>
</table>

## 고마운 분들

Issue나 Pull Request를 남겨 주신 모든 분께 감사드리며, 여러분의 제보와 수정 덕분에 Poki가 더 좋아지고 있습니다.

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

## 기타 도구

[Poki MCP](docs/poki-mcp.md)는 컴퓨터의 에이전트를 iPhone이나 iOS 시뮬레이터에 연결하는 이전 도구이며, 현재는 업데이트하지 않습니다.

[Poki Agent](docs/poki-mcp.md#try-a-task-with-poki-agent)는 iMessage와 Telegram 채널을 지원하는 터미널 에이전트입니다. 설치와 사용법은 링크된 가이드에 있습니다.

## 면책 조항

Poki는 독립적인 오픈소스 프로젝트입니다. Apple, OpenAI 또는 Poki가 조작하는 앱이나 웹사이트의 제작사와 제휴 관계가 없으며, 이들의 보증을 받지 않았습니다. iPhone은 Apple Inc.의 상표입니다.

타사 앱과 웹사이트를 자동으로 조작하면 해당 서비스 약관을 위반할 수 있습니다. 특정 서비스에서 Poki를 쓸지는 직접 판단하세요. 사용자의 기기와 계정에서 Poki가 하는 일(보낸 메시지, 변경한 내용, 그 결과로 생긴 계정 제한 포함)에 대한 책임은 사용자에게 있습니다.

Poki는 AGPL-3.0 라이선스에 명시된 대로 어떠한 보증도 없이 "있는 그대로" 제공됩니다.

## 라이선스

Poki의 코드는 [AGPL-3.0-only 라이선스](LICENSE)에 따라 공개된 오픈소스입니다.

Poki 곰, 앱 아이콘과 Poki의 다른 아트워크는 이 라이선스에 포함되지 않습니다. Poki를 소개할 때 스크린샷은 사용할 수 있지만, 포크는 자체 이름과 아트워크를 사용해야 합니다. 자세한 내용은 [BRAND.md](BRAND.md)를 참고하세요.

Copyright (c) 2026 Joseph Zhou (周瑟夫) and contributors. 오픈소스 의존성과 서드파티 에셋은 각자의 라이선스를 따릅니다. [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)를 참고하세요. 기여하려면 [CONTRIBUTING.md](CONTRIBUTING.md)를 읽어 보세요.

## 감사의 말

Poki가 사용하는 오픈소스 의존성과 에셋은 [서드파티 고지](THIRD_PARTY_NOTICES.md)를 확인하세요.
