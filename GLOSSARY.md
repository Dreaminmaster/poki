# Poki Glossary

Poki is an iPhone assistant that operates the phone on its owner's behalf, paired with desktop tools that install it and let external agents control the device. This glossary defines each product concept once so code, documentation, issues, and agents use consistent terminology. The _zh-Hans UI_ line gives the Simplified Chinese name the app interface uses for that term.

## Products

**Poki**:
The personal assistant that operates the owner's iPhone, and the name of the overall product suite.
_Related_: Poki app, Poki MCP
_Avoid_: the bot, the robot
_zh-Hans UI_: Poki

**Poki app**:
The iPhone app where the owner chats with Poki and where Poki completes tasks across other apps without needing a computer.
_Related_: Poki Runner, Conversation
_Avoid_: iOS app, client, phone agent
_zh-Hans UI_: Poki App

**Poki Runner**:
An optional separate helper app that can carry out Poki's control of other apps. By default the Poki app does this itself.
_Related_: Automation session, Poki app
_Avoid_: runner app, test runner, automation helper
_zh-Hans UI_: Poki Runner

**Poki Setup**:
The Mac and Windows application that installs the Poki app on an iPhone and renews its Apple signature.
_Related_: Pairing, Renewal
_Avoid_: installer, setup app, desktop app
_zh-Hans UI_: Poki Setup

**Poki MCP**:
The local computer service that lets MCP clients, such as coding agents, view and control a connected iPhone or simulator.
_Related_: External agent, Device lease
_Avoid_: daemon, MCP server, bridge
_zh-Hans UI_: Poki MCP

**Poki Agent**:
The standalone terminal agent on a computer that can also respond through messaging channels.
_Related_: Messaging channel, Poki MCP
_Avoid_: CLI agent, terminal Poki
_zh-Hans UI_: Poki Agent

## Working on the iPhone

**Task**:
A single unit of work that the owner or an agent asks Poki to complete, such as ordering lunch or replying to a message.
_Related_: Step, Conversation
_Avoid_: job, request, command, to-do
_zh-Hans UI_: 任务

**Step**:
A single action Poki performs within a task, such as tapping a button, entering text, or opening an app.
_Related_: Task, Approval
_Avoid_: move, operation
_zh-Hans UI_: 步骤

**Conversation**:
A message thread between the owner and Poki, including all tasks executed within that thread.
_Related_: Task
_Avoid_: session, chat thread
_zh-Hans UI_: 对话

**Sensitive step**:
A step that makes a payment, deletes data, sends a message, places a call, enters a password, or interacts with Wallet.
_Related_: Approval, Handoff
_Avoid_: dangerous action, risky step
_zh-Hans UI_: 敏感步骤

**Approval**:
The owner's explicit decision to allow or block a sensitive step before Poki performs it.
_Related_: Sensitive step, Auto-classifier, Operator approval
_Avoid_: confirmation, permission, consent
_zh-Hans UI_: 操作确认

**Auto-classifier**:
An optional setting that lets the owner's chat model handle approvals on their behalf at a Permissive, Balanced, Strict or Ask All level.
_Related_: Approval, Activity log
_Avoid_: approval mode, auto-approve, AI approver
_zh-Hans UI_: 确认严格度（宽松、适中、严格、每次都问）

**Takeover**:
When the owner reclaims control of the iPhone from Poki during an active task. The owner can hand back control when ready for Poki to continue.
_Related_: Hand back, Handoff
_Avoid_: interrupt, pause
_zh-Hans UI_: 手动接管

**Handoff**:
When Poki stops at a step only the owner should do, such as paying, and gives the iPhone to the owner until they hand it back.
_Related_: Hand back, Sensitive step, Takeover
_Avoid_: takeover, escalation
_zh-Hans UI_: 交给你操作

**Hand back**:
Returning control of the iPhone to Poki after a takeover or handoff so the task continues from where it paused.
_Related_: Takeover, Handoff
_Avoid_: resume, give back
_zh-Hans UI_: 交回给 Poki

**Automation session**:
The active period during which Poki controls the iPhone to interact with other apps, indicated by a system banner in iOS.
_Related_: Poki Runner, Step
_Avoid_: session, test session
_zh-Hans UI_: 自动操作状态

**App capsule**:
An inline badge displaying an app's icon and name whenever Poki mentions that app in text.
_Related_: Conversation
_Avoid_: pill, chip, app tag
_zh-Hans UI_: App 胶囊

**Result card**:
A structured native card in a conversation that presents task outcomes, such as flight options, rather than plain text.
_Related_: Task, Suggestion card
_Avoid_: rich reply, widget
_zh-Hans UI_: 结果卡片

**Suggestion card**:
A proactive card Poki displays when a habit is due. It offers the usual action, a few alternatives, and a text field so the owner can start the task with one tap.
_Related_: Habit, Result card
_Avoid_: choice card, nudge, popup
_zh-Hans UI_: 建议卡

## Memory

**Memory library**:
Everything Poki keeps about its owner on the iPhone, in four kinds: memories, skills, habits and to-dos. Every agent operating the phone shares this library.
_Related_: Memory, Skill, Habit, To-do, Memory page
_Avoid_: memory store, brain, knowledge base
_zh-Hans UI_: 记忆库

**Memory**:
A single detail Poki remembers about the owner's preferences or personal context, such as dietary restrictions or a home address. Each memory is either global or tagged with a specific app.
_Related_: Global memory, App memory, Memory library
_Avoid_: note, fact, preference entry
_zh-Hans UI_: 记忆

**Global memory**:
A memory without an app tag that Poki applies across all tasks. Global memories appear under About You on the Memory page.
_Related_: App memory, Rule, Your people
_Avoid_: always-on memory, core memory, permanent memory
_zh-Hans UI_: 常驻记忆

**App memory**:
A memory tagged with a specific app that Poki applies only when working inside that app.
_Related_: App tag, Global memory
_Avoid_: app note, app preference
_zh-Hans UI_: App 记忆

**App tag**:
The specific app associated with a memory, skill, or habit.
_Related_: App memory, Skill
_Avoid_: app label, category
_zh-Hans UI_: App 标签

**Rule**:
A locked global or app memory created by the owner that instructs Poki to always or never perform a specific behavior.
_Related_: Locked, Global memory
_Avoid_: policy, setting
_zh-Hans UI_: 规则

**Skill**:
A reusable procedure for one task in one app, saved after Poki completes that task, so Poki can repeat it in one go next time.
_Related_: App tag, Habit, Agent skill
_Avoid_: routine, flow, workflow, playbook, macro
_zh-Hans UI_: 技能

**Agent skill**:
A packaged instruction set that teaches an external coding agent how to install or operate Poki. It belongs to the external agent rather than the on-device Memory library.
_Related_: Skill, External agent
_Avoid_: Poki skill, skill (on its own, when Skill could be meant)
_zh-Hans UI_: Agent 技能

**Habit**:
A recurring action the owner takes around the same time in a specific app, linked to the supporting skill, relevant memories, and the reason Poki identified it.
_Related_: Skill, Suggestion card, Reason, Behavior log
_Avoid_: routine, pattern, schedule
_zh-Hans UI_: 习惯

**To-do**:
Something the owner has agreed to do, phrased as one sentence from the owner's side with a due time and the app it came from, which Poki reminds the owner about when it is due. To-dos are their own kind in the Memory library.
_Related_: Memory library, Your people, Task
_Avoid_: task, reminder, commitment
_zh-Hans UI_: 待办

**Your people**:
Global memories about the people the owner refers to by name or relationship, such as "Mom", each linked to a contact with an address, a birthday, and the app the owner usually uses to reach them. They appear under About You on the Memory page.
_Related_: Global memory, To-do
_Avoid_: contacts, relationships, social graph
_zh-Hans UI_: 身边的人

**Source**:
How a memory or habit was created or updated, whether stated directly by the owner, learned during a conversation, discovered in a Dream, or edited manually.
_Related_: Reason, Locked
_Avoid_: origin, provenance
_zh-Hans UI_: 来源

**Reason**:
The supporting evidence Poki displays for a habit or learned memory to show why Poki inferred it.
_Related_: Habit, Source
_Avoid_: basis, justification, explanation
_zh-Hans UI_: 依据

**Locked**:
The state of any item added or edited by the owner, allowing Poki to read the item while preventing automatic edits or merges.
_Related_: Rule, Source
_Avoid_: pinned, protected, frozen
_zh-Hans UI_: 已锁定

**Recent updates**:
A view on the Memory page listing the latest items Poki learned or modified, accessible by tapping "Memory updated" in a conversation.
_Related_: Memory page, Dream
_Avoid_: changelog, history, activity
_zh-Hans UI_: 最近更新

**Memory page**:
The dedicated screen in the Poki app where the owner views, edits, and deletes saved context, organized with About You at the top followed by individual apps.
_Related_: Memory library, Recent updates
_Avoid_: notes page, memory list
_zh-Hans UI_: 记忆页

**Dream**:
An automated maintenance pass that runs overnight while the iPhone charges, analyzing the behavior log and recent tasks to add, update, or remove memories, habits, and skills.
_Related_: Behavior log, Habit, Recent updates
_Avoid_: Nightly review, consolidation, background review, sync
_zh-Hans UI_: 做梦

**Screen history**:
The owner's private record on the iPhone of what was on screen and when, kept behind its own PIN.
_Related_: Screen observation, Behavior log
_Avoid_: activity log, screen recording, timeline
_zh-Hans UI_: 屏幕记录

**Screen observation**:
The background feature where Poki observes on-screen activity while the owner uses other apps, automatically ignoring excluded apps.
_Related_: Screen history, Excluded apps
_Avoid_: monitoring, surveillance, tracking
_zh-Hans UI_: 屏幕理解

**Excluded apps**:
Apps omitted from screen observation to protect sensitive information, such as password managers, banking apps, and payment tools.
_Related_: Screen observation
_Avoid_: blocklist, private apps
_zh-Hans UI_: 排除的 App

**Behavior log**:
A concise daily summary distilled from screen history that captures when the owner used an app and what they did inside it.
_Related_: Screen history, Dream, Habit
_Avoid_: activity log, usage log
_zh-Hans UI_: 行为日志

**Activity log**:
The chronological record of actions taken by agents on the iPhone and how each approval was resolved.
_Related_: Approval, Step
_Avoid_: behavior log, screen history, audit log
_zh-Hans UI_: 活动记录

## Agents and connections

**External agent**:
An agent running outside the Poki app, such as a desktop coding agent, that controls the iPhone through Poki.
_Related_: Connector, Guest, Poki MCP
_Avoid_: outside agent, client, third-party agent
_zh-Hans UI_: 外部智能体

**Guest**:
An external agent while it is operating the iPhone, shown to the owner so they can stop it at any time.
_Related_: External agent, Takeover
_Avoid_: visitor, remote user
_zh-Hans UI_: 访客

**Connector**:
The unique connection address an external agent uses to reach the iPhone through the owner's relay.
_Related_: Relay, External agent
_Avoid_: endpoint, MCP URL, integration
_zh-Hans UI_: 外部 AI 入口

**Relay**:
A forwarding service on the internet, deployed by the owner, that routes requests from external agents to the iPhone when the phone is away from the computer.
_Related_: Connector, External agent
_Avoid_: proxy, tunnel, cloud server
_zh-Hans UI_: 远程连接服务

**Local connection**:
The connection built into the Poki app that routes traffic back to the same iPhone, so Poki can reach the phone's developer services without another app.
_Related_: Loopback, External connection
_Avoid_: VPN, tunnel, built-in VPN
_zh-Hans UI_: Poki 内置通道

**External connection**:
A compatible VPN or proxy app the owner already uses, set up to provide the loopback in place of the local connection.
_Related_: Loopback, Local connection
_Avoid_: third-party VPN, external VPN
_zh-Hans UI_: 外部代理通道

**Loopback**:
The route back to the iPhone itself, provided by the local connection or an external connection. Poki requires an active loopback to tap and type.
_Related_: Local connection, External connection, Pairing
_Avoid_: localhost, VPN
_zh-Hans UI_: 本机通道

**Voice bridge**:
A lightweight Mac utility that issues short-lived credentials for live voice sessions so the iPhone never stores persistent voice API keys.
_Related_: Poki app
_Avoid_: voice server, voice relay
_zh-Hans UI_: 语音桥接

**Messaging channel**:
An external chat platform, such as iMessage or Telegram, that the owner uses to communicate with Poki Agent.
_Related_: Poki Agent
_Avoid_: channel (on its own), gateway, provider
_zh-Hans UI_: 渠道

**Device lease**:
Exclusive control of an iPhone or simulator granted to a single MCP session so multiple agents do not conflict.
_Related_: Poki MCP, External agent
_Avoid_: lock, reservation, claim
_zh-Hans UI_: none (Poki MCP only, English)

**Operator approval**:
Explicit confirmation given by the user at the computer before Poki MCP performs sensitive host or device actions, such as installing apps, opening links, or reading the clipboard.
_Related_: Approval, Poki MCP
_Avoid_: approval (on its own), permission
_zh-Hans UI_: none (Poki MCP only, English)

## Installing and updating

**Pairing**:
The trust that lets Poki, Poki Setup or Poki MCP reach the iPhone's developer services. It is made from a computer over USB, or on the iPhone itself on recent iOS versions.
_Related_: Poki Setup, Loopback
_Avoid_: linking, binding
_zh-Hans UI_: 配对

**Signing**:
The Apple code signature that authorizes the Poki app to run on an iPhone. Signatures created with a free Apple Account expire after seven days.
_Related_: Renewal, Poki Setup
_Avoid_: certificate, provisioning
_zh-Hans UI_: 安装签名

**Renewal**:
Re-applying the Apple code signature to an installed Poki app before the current signature expires, from Poki Setup or from the Poki app itself.
_Related_: Signing, Poki Setup
_Avoid_: refresh, re-sign, reinstall
_zh-Hans UI_: 续期

**Release channel**:
The line of builds a Poki installation follows for updates, such as Beta.
_Related_: Poki Setup
_Avoid_: channel (on its own), track, ring
_zh-Hans UI_: 更新通道
