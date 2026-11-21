---
name: iphone-unlock
description: 手机锁屏或面容 ID 有密码入口时，用本机配置的密码解锁，并以当前截图核实结果。
license: AGPL-3.0-only
---

# iPhone 解锁

Poki Agent 通过 unlock_device 加载本技能并调用本地助手。模型只提供设备页面的确认信息，密码由宿主读取 POKI_IPHONE_PASSCODE，通过子进程标准输入传递。密码不进入模型输入、参数、日志、证据和提交。缺少本机密码时工具返回明确错误，模型根据任务和可用能力继续解决，无法完成就 finish_task(success=false)。

1. 先观察当前屏幕。已经解锁时直接继续原任务。面容 ID 有密码入口时进入密码页。
2. 本助手只点按 4 位或 6 位数字密码。核对当前截图与 [键盘布局](references/iphone-402x874.json) 一致，为普通 iPhone 402×874 逻辑点、竖屏的数字键盘。输入圆点应为空。自定义数字或含字母的密码要输入到锁屏密码栏，助手看不到该栏，盲目按键可能把密码输进已打开的应用，所以会拒绝且不发送任何输入。这时请机主自己解锁，或使用 iPhone 上 Poki 的自动解锁（它先确认锁屏）。
3. 调用 unlock_device，传 keypadConfirmed=true。宿主取得设备租约后执行连续输入，并返回截图。工具输出只代表输入发送，是否解锁要以截图为准。输入结果不明时先观察当前状态，避免重复已发送的数字。
4. 核验锁屏已退出、当前应用明确，再继续原任务。

本地助手来自本仓库提交 5134e1a。编译命令：

```sh
cargo build --locked --release --manifest-path native/bridge/Cargo.toml --target-dir build/native-target --example unlock_iphone -j 4
```

命令行独立使用可运行 scripts/unlock.py --device '<UDID>'，密码通过隐藏终端输入。宿主模式添加 --stdin，原生程序可由 POKI_UNLOCK_NATIVE 指定。原始真机验证记录见 [verified-run.md](references/verified-run.md)；本次接入验证使用假助手，未执行真实解锁。
