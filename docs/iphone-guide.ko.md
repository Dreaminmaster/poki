# Poki iPhone 앱 가이드

[English](iphone-guide.md) | [简体中文](iphone-guide.zh-CN.md) | [繁體中文](iphone-guide.zh-TW.md) | [日本語](iphone-guide.ja.md) | 한국어 | [Español](iphone-guide.es.md)

이 가이드는 Poki iPhone 앱의 전체 시스템 요구 사항, 설치 안내, 업데이트, 자주 묻는 질문, 알려진 제한, 작업 예제를 다룹니다.

버전별 변경 사항은 [CHANGELOG.md](../CHANGELOG.md)를 확인하세요.

## 준비할 것

| | 요구 사항 |
| --- | --- |
| iPhone | iOS 18 이상인 iPhone XS, XR, SE(2세대) 또는 이후 기종. 실제 기기 테스트는 iOS 27이 설치된 iPhone에서 진행했습니다. |
| 컴퓨터 | macOS 14 이상인 Mac, 또는 Apple Devices나 iTunes가 설치된 Windows PC(x64). Mac에서 에이전트가 설치 스크립트를 사용하려면 Node.js 24 이상도 필요합니다. |
| 케이블과 계정 | USB 데이터 케이블과 Apple 계정. 무료 계정의 서명은 7일간 유효하며 Poki Setup이 갱신할 수 있습니다. |
| 연결 | `10.7.0.1`을 iPhone 자체로 연결하는 VPN 앱. App Store의 무료 LocalDevVPN이나 Poki의 안내에 따라 설정한 Karing, Shadowrocket을 사용할 수 있습니다. |
| 모델 계정 | 본인 계정이 필요합니다. ChatGPT Plus 또는 Pro 로그인이 간편한 시작 방법입니다. Anthropic, OpenAI, Gemini, DeepSeek, OpenRouter, OpenCode Go의 API 키나 자체 OpenAI 호환 서버도 사용할 수 있습니다. Claude 구독으로는 로그인할 수 없으므로 Anthropic API 키를 사용하세요. |

iOS 27 이상에서는 네이티브 서비스로 iPhone을 조작합니다. iOS 18부터 26까지는 XCTest 세션을 사용하므로 iPhone 개발자 설정에서 UI 자동화를 켜야 합니다. iPadOS 18 이상인 iPad에도 설치할 수 있습니다.

iPhone 앱에는 본인의 모델 계정이 필요합니다. 코딩 에이전트의 구독이 Poki에 자동으로 연결되지는 않습니다. 기존 에이전트에서 Poki MCP만 사용하려면 [MCP 설치 안내](install.md)를 따르세요. MCP는 해당 클라이언트의 모델 연결을 사용합니다.

## 설치 안내

### 원클릭 설치 (권장)

직접 할 일은 iPhone 연결과 잠금 해제, 안내에 따른 로그인, iPhone 권한, 로컬 연결, 모델 계정 설정뿐입니다.

Claude Code나 Codex 같은 에이전트에게 다음과 같이 요청하세요.

```text
Install Poki on my iPhone from https://github.com/JosssphZhou/poki
```

에이전트는 [install-poki 스킬](../skills/install-poki/SKILL.md)에 따라 `bin/install-iphone.mjs`를 실행해 자동화할 수 있는 단계를 처리합니다. 사용자는 Mac의 Poki Setup 창에서 Apple 계정 입력, iPhone에서 신뢰 선택, 개발자 모드 활성화, 개발자 신뢰, Poki 실행을 직접 합니다. 처음 열 때 자동화 모드를 요청하면 계속을 누르고 iPhone 암호를 입력하세요. 취소했다면 Poki를 다시 켜면 요청이 다시 표시됩니다. 직접 해야 할 단계마다 에이전트가 안내합니다. 무료 Apple 계정도 사용할 수 있습니다.

현재 설치 프로그램은 Beta를 선택합니다. 이전 Stable, Alpha, Pre-alpha 설정도 Beta로 처리하며, Beta가 없으면 중단합니다. 이미 설치한 구버전 Poki Setup은 이전 선택 방식을 사용할 수 있으므로 이번 설치에 표시되는 버전을 확인하세요.

Node.js 24가 없거나 Windows를 사용하나요? Poki Setup을 설치하면 같은 요청을 사용할 수 있습니다. 에이전트가 내장 명령줄 도구를 사용합니다. Poki Setup 메뉴에서도 요청문을 복사할 수 있습니다. Mac은 `Poki > Copy Prompt for Your Agent`, Windows는 `Settings > Use an agent`입니다.

설치 프로그램이 릴리스 정보를 읽다가 GitHub에서 403 또는 429를 받으면, 같은 네트워크에서 공유하는 시간당 익명 요청 한도에 도달한 경우가 많습니다. 다른 네트워크나 프록시 서버로 다시 시도하거나 한 시간 기다리세요.

### Poki Setup으로 설치하기

설치 파일이 포함된 최신 [Beta 릴리스](https://github.com/JosssphZhou/poki/releases)에서 macOS용 Poki Setup(`.dmg`) 또는 Windows용(`.exe`, [ZhehanZhang](https://github.com/ZhehanZhang) 기여)을 내려받아 안내를 따르세요. 자세한 단계는 [Poki Setup](../desktop/README.md)을 참고하세요.

### 첫 작업 실행하기

설치된 버전을 확인하고 로컬 연결과 모델 계정 설정을 마쳤다면 Poki에서 다음 요청을 보내세요.

```text
Create a new note in Notes titled "Poki Demo" with these three lines: Milk, Eggs, Coffee. Open the note when finished. Leave existing notes unchanged.
```

메모 앱에서 제목이 "Poki Demo"이고 본문 세 줄이 각각 Milk, Eggs, Coffee인지 확인하세요. 완료 메시지만으로는 성공을 확인할 수 없습니다. 메모 앱이 없거나 설정이 끝나지 않았다면 먼저 해당 단계를 완료하세요. 중단 후 다시 시도하기 전에 메모가 이미 만들어졌는지 확인하세요.

## 자주 묻는 질문

**Windows에서도 설치할 수 있나요?** 네. Windows용 Poki Setup은 Mac 버전처럼 설치, 페어링, 서명 갱신을 지원합니다. PC가 iPhone을 인식하도록 Apple Devices 또는 iTunes를 먼저 설치하세요. [Poki Setup](../desktop/README.md)을 참고하세요.

**설치 후에도 컴퓨터가 필요한가요?** 작업 실행에는 필요하지 않습니다. Poki는 iPhone에서 독립적으로 작동합니다. 무료 Apple 계정이라면 컴퓨터에서 Poki Setup을 계속 실행해 서명을 갱신하거나, Poki에서 Apple 계정에 로그인해 iPhone이 직접 갱신하도록 할 수 있습니다. 로그인이 실패하면 컴퓨터의 Poki Setup을 사용하세요. [계속 실행해 둘 항목](../skills/install-poki/SKILL.md#what-to-keep-running)을 참고하세요.

**무료 Apple 계정도 되나요? 7일 제한은 무엇인가요?** 사용할 수 있지만 Apple이 발급하는 서명은 7일간만 유효합니다. Poki Setup이 실행 중이고 컴퓨터가 깨어 있으며 iPhone에 연결할 수 있으면, 6시간마다 확인해 유효 기간이 2일 이하인 앱의 서명을 갱신합니다. 갱신하지 않으면 만료 후 앱을 열 수 없으므로 Poki가 마지막 2일 동안 알려 줍니다. [유료 개발자 계정이 없는 경우](../skills/install-poki/SKILL.md#no-paid-developer-account)를 참고하세요.

**어떤 iPhone과 iOS가 필요한가요?** iOS 18 이상인 iPhone XS, XR, SE(2세대) 또는 이후 기종이며, iPadOS 18 이상인 iPad에도 설치할 수 있습니다. 실제 기기 테스트는 iOS 27에서 진행했습니다. 다른 제어 방식을 사용하는 iOS 18부터 26까지는 실제 iPhone에서 아직 검증하지 않았습니다. [검증 결과와 알려진 제한](verification.md)을 참고하세요.

**내 모델 계정이 필요한가요?** 네. ChatGPT Plus 또는 Pro로 로그인하거나 Anthropic, OpenAI, Gemini, DeepSeek, OpenRouter, OpenCode Go의 API 키 또는 자체 OpenAI 호환 서버를 사용하세요. 음성 대화에는 음성 모델 키도 필요합니다. [준비할 것](#준비할-것)을 참고하세요.

**중국 본토 네트워크 등에서 업데이트가 보이지 않으면 어떻게 하나요?** Poki는 GitHub에서 업데이트를 확인합니다. 일부 네트워크는 접속할 수 없거나 403, 429 요청 제한에 걸립니다. 다른 네트워크나 프록시 서버를 사용하거나, 컴퓨터의 Poki Setup에서 Renew로 업데이트하세요. [Poki 업데이트하기](#poki-업데이트하기)를 참고하세요.

**내 iPhone의 내용을 변경하나요? 먼저 물어보나요?** 실제 앱에서 메시지 전송 등 요청한 작업을 수행하며, 화면 내용은 설정한 모델 서비스로 전송됩니다. 결제와 삭제, Wallet 작업은 항상 확인을 받습니다. 메시지 전송이나 암호 입력 같은 다른 민감한 단계는 `Settings > Approvals`에서 확인 방법이나 확인 여부를 선택할 수 있습니다. [알려진 문제](#알려진-문제)를 참고하세요.

## Poki 업데이트하기

- **iPhone에서 업데이트.** Poki의 서명 및 업데이트 페이지를 여세요. 현재 빌드에서는 `Settings > Signing & Updates`입니다. 구버전에서는 Connection 아래에 있을 수 있습니다. 새 빌드가 있으면 다운로드하고 설치할 수 있습니다. 먼저 로그인을 요청한다면 컴퓨터에서 설치했기 때문에 iPhone에 Apple 계정이 아직 없는 상태입니다. 설치할 때 쓴 계정으로 로그인하거나 컴퓨터에서 업데이트하세요.
- **컴퓨터에서 업데이트.** Poki Setup의 Renew는 선택한 채널의 최신 빌드를 기존 앱 위에 설치합니다. Mac에서는 에이전트에게 "내 iPhone의 Poki를 업데이트해 줘"라고 요청할 수도 있습니다. install-poki 스킬은 설치된 버전과 서명 정보를 먼저 확인하는 별도 업데이트 절차를 제공합니다.
- 업데이트가 "Finishing the update"에서 멈추면 앱 전환기에서 Poki를 종료한 뒤 다시 열고 설정에서 버전을 확인하세요. 버전이 바뀌지 않았다면 컴퓨터의 Poki Setup으로 업데이트하세요. 업데이트 문제를 해결하려고 Poki를 삭제하지 마세요. 대화도 함께 삭제됩니다.

채널과 Alpha에서 Beta로 빌드가 이동하는 절차는 [릴리스 채널](release-channels.md)을 참고하세요.

## 작업 실행해 보기

Poki를 열고 "내일 날씨를 확인해서 우산이 필요한지 알려 줘" 같은 작업을 입력하거나 홈 화면에서 앱을 눌러 시작하세요. Poki가 화면의 앱을 조작하고 Dynamic Island와 잠금 화면에 각 단계를 표시하며 설정에 따라 승인을 요청합니다.

Poki를 열지 않고 부를 수도 있습니다. 동작 버튼을 길게 눌러 대화하거나 단축어와 Siri에서 Talk to Poki 또는 Send Task to Poki를 사용하세요. 이 방식으로 보낸 작업의 결과는 알림으로 도착합니다. iPhone Duo의 Split View에서는 두 앱을 나란히 놓고 작업할 수 있습니다.

> **참고:** Poki는 실제 iPhone을 제어합니다. 메시지 전송이나 결제를 요청하면 실행합니다.

## 알려진 문제

- Poki는 실제 iPhone을 조작하며 요청한 메시지 전송이나 결제를 실행합니다. 화면 내용은 설정한 모델 서비스로 전송됩니다.
- iPhone에서 Apple 계정에 로그인할 수 없으면 컴퓨터의 Poki Setup으로 서명을 갱신하고 앱을 업데이트하세요.
- 실제 기기 지원은 중국어 인터페이스와 세로 방향의 iPhone에서만 검증했습니다. 가로 방향은 지원하지 않습니다.
- 이 릴리스는 iOS 27 미만의 실제 iPhone이나 iPad에서 테스트하지 않았습니다. 오래되거나 작은 iPhone에서는 입체 곰과 홈 화면 애니메이션으로 발열이나 지연이 생길 수 있습니다. 저전력 모드나 동작 줄이기를 켜면 곰을 정지 이미지로 표시합니다.
- 무료 Apple 계정의 서명은 7일간 유효합니다. 컴퓨터의 Poki Setup이 iPhone에 연결할 수 있도록 유지하거나 만료 전에 수동 갱신하세요.
- GitHub 릴리스 조회가 403 또는 429로 실패할 수 있으며, 여러 사람이 네트워크를 공유할 때 흔히 발생합니다. 네트워크나 프록시 서버를 바꾸거나 한 시간 기다리세요.

더 많은 제한과 테스트 결과는 [검증 결과와 알려진 제한](verification.md)을 참고하세요.

## 로드맵

날짜를 약속하는 일정이 아니라 앞으로의 방향입니다. 출시된 기능은 [CHANGELOG.md](../CHANGELOG.md)에 기록되어 있습니다.

**Released in 0.4 Beta**

- 설정 후 컴퓨터 없이 작업을 실행하는 iPhone 앱과 잠금 화면 및 Dynamic Island에서의 승인.
- 무료 Apple 계정으로 Mac 또는 Windows의 에이전트나 Poki Setup을 통한 설치.
- iOS 27 이상의 네이티브 제어와 Poki 내장 브라우저에서의 웹 작업.
- 입체 곰이 있는 홈 화면, 음성 대화, 동작 버튼, 대화 보관, iPhone Duo Split View, 조절 가능한 인터페이스 크기, 다크 모드.

**진행 중**

- 더 안정적인 업데이트 전달과 통합 업데이트 처리.
- 더 많은 인터페이스 언어.

**계획됨**

- 더 많은 iPhone, iOS 버전, 화면 언어를 실제 기기에서 검증.
- 더 많은 모델 제공업체 지원.

## 기타 도구

[Poki MCP](poki-mcp.md)는 컴퓨터의 에이전트를 iPhone이나 iOS 시뮬레이터에 연결하는 이전 도구이며, 현재는 업데이트하지 않습니다.

[Poki Agent](poki-mcp.md#try-a-task-with-poki-agent)는 iMessage와 Telegram 채널을 지원하는 터미널 에이전트입니다. 설치와 사용법은 링크된 가이드에 있습니다.

## 면책 조항

Poki는 독립적인 오픈소스 프로젝트입니다. Apple, OpenAI 또는 Poki가 조작하는 앱이나 웹사이트의 제작사와 제휴 관계가 없으며, 이들의 보증을 받지 않았습니다. iPhone은 Apple Inc.의 상표입니다.

타사 앱과 웹사이트를 자동으로 조작하면 해당 서비스 약관을 위반할 수 있습니다. 특정 서비스에서 Poki를 쓸지는 직접 판단하세요. 사용자의 기기와 계정에서 Poki가 하는 일(보낸 메시지, 변경한 내용, 그 결과로 생긴 계정 제한 포함)에 대한 책임은 사용자에게 있습니다.

Poki는 AGPL-3.0 라이선스에 명시된 대로 어떠한 보증도 없이 "있는 그대로" 제공됩니다.

## 라이선스

Poki의 코드는 [AGPL-3.0-only 라이선스](../LICENSE)에 따라 공개된 오픈소스입니다.

Poki 곰, 앱 아이콘과 Poki의 다른 아트워크는 이 라이선스에 포함되지 않습니다. Poki를 소개할 때 스크린샷은 사용할 수 있지만, 포크는 자체 이름과 아트워크를 사용해야 합니다. 자세한 내용은 [BRAND.md](../BRAND.md)를 참고하세요.

Copyright (c) 2026 Joseph Zhou (周瑟夫) and contributors. 오픈소스 의존성과 서드파티 에셋은 각자의 라이선스를 따릅니다. [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md)를 참고하세요. 기여하려면 [CONTRIBUTING.md](../CONTRIBUTING.md)를 읽어 보세요.
