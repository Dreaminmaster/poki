# Poki MCP and Poki Agent

Poki MCP is the earlier way to use Poki: an agent on your Mac, such as Claude Code or Codex, drives an iPhone or the iOS Simulator, and Poki Agent, a terminal agent with iMessage and Telegram channels, runs on it. It is no longer updated and stays here as it is for people who already use it or want to build on it. For a maintained way to run Poki, [install the Poki app](../README.md#install-poki-on-your-iphone) on your iPhone.

**Let your agent install it.** Copy this to your agent:

```text
Install https://github.com/JosssphZhou/poki following its root AGENTS.md, including the MCP skill, and stop whenever you need me to act.
```

**Poki MCP.** Already using Claude Code, Codex, or another MCP client? Connect Poki MCP and use your own subscription. No extra model account needed.

Start the server and keep it running:

```sh
git clone https://github.com/JosssphZhou/poki.git
cd poki
./bin/setup
npm start
```

Poki MCP builds from source, so it has its own requirements: macOS 15 or later, full Xcode, Rust, Node.js 24+, Python 3, and ffmpeg. The Poki app does not need Xcode. `./bin/setup` checks for missing dependencies. The initial build takes a few minutes.

Poki targets macOS. For Linux, see the community port [poki-for-linux](https://github.com/carrotciallo/poki-for-linux) ([#16](https://github.com/JosssphZhou/poki/issues/16)), maintained outside this repo.

Poki MCP on Windows: community port at [scy7796/poki-for-windows](https://github.com/scy7796/poki-for-windows) (maintained by its author, not tested by us).

## Prebuilt macOS arm64 package

Download `poki-v0.1.1-macos-arm64.tar.gz` from the [Poki MCP v0.1.1 release](https://github.com/JosssphZhou/poki/releases/tag/v0.1.1) and run:

```sh
tar -xzf poki-v0.1.1-macos-arm64.tar.gz
cd poki-v0.1.1
npm ci --no-audit --no-fund
npm start
```

Poki MCP releases are tagged `vX.Y.Z`. The iPhone app's `app-` releases do not carry this package. The package includes the native bridge and idevice tools. You do not need Rust or `./bin/setup`. You still need macOS on Apple Silicon, full Xcode, Node.js 24+, Python 3, and ffmpeg. Register your MCP client and install the optional Agent as described below.

In another terminal, from the same directory, register the MCP server:

```sh
claude mcp add --scope user poki-mcp -- node "$PWD/src/stdio.mjs"   # Claude Code
codex mcp add poki-mcp -- node "$PWD/src/stdio.mjs"                 # Codex
```

**Poki Agent.** For Poki's standalone terminal agent or messaging channels, keep `npm start` running and open another terminal in the same directory. Install the agent, add its command to this terminal's path, and sign in:

```sh
npm ci --prefix agent
export PATH="$PWD/bin:$PATH"
poki login
poki status
```

Poki Agent uses GPT-6.1 Terra (`gpt-6.1-terra`) with low reasoning by default. We recommend keeping it: it is the fastest setup we have tested for phone tasks. Override it with `POKI_AGENT_MODEL`; see [Run Poki Agent](../agent/README.md).

For a physical iPhone, pair it with your Mac over USB first. See [Physical iPhone setup](physical-iphone.md).

`./bin/poki update` still pulls the newest `main` and rebuilds. See [Update](../AGENTS.md#update) for the restart steps and the optional update check.

## Try a task with Poki Agent

With Poki Agent, one connected iPhone is selected automatically. With multiple devices, add `--device '<device UUID>'`.

```sh
node bin/call.mjs list_devices   # Find your device UUID
poki "Search esp32 in Chrome and summarize the top result"
```

> **Note:** Poki controls your real iPhone. If you ask it to send messages or make payments, it will. Screen contents are sent to your configured model service.

Gets faster with use: Poki Agent remembers past tasks and runs them faster on repeat.

**Channels:** After configuring an authorized channel, start it with `poki imessage` or [`poki telegram`](../agent/README.md#telegram). See [Poki Agent](../agent/README.md) for setup.

**MCP clients:** Claude Code, Codex, and any client supporting `mcpServers` JSON.

On physical devices, app container export and direct links to Settings subpages are unavailable. See [verification and known limits](verification.md).


## Reference

| Topic | Read |
| --- | --- |
| Poki MCP installation, other MCP clients, and troubleshooting (no longer updated) | [Install guide](install.md) |
| Poki Agent, models, iMessage, and Telegram | [Run Poki Agent](../agent/README.md) |
| MCP tool reference | [Tool behavior](tools.md) |
| Environment variables and sessions | [Configuration](configuration.md) |
| USB pairing, Developer Mode, and Wi-Fi | [Physical iPhone setup](physical-iphone.md) |
| Bridge architecture | [Native bridge](../native/NATIVE.md) and [simulator adapter](../native/simulator.md) |

## Acknowledgments

<p align="center">
  <img src="images/acknowledgments.png" width="860" alt="Built on open source: pi, idevice, idb, BlueBubbles, Hermes Agent, MCP SDK, sharp, and FFmpeg"><br>
  <sub>Open source acknowledgments: <a href="https://github.com/earendil-works/pi">pi</a> | <a href="https://github.com/jkcoxson/idevice">idevice</a> | <a href="https://github.com/facebook/idb">idb</a> | <a href="https://github.com/BlueBubblesApp/bluebubbles-server">BlueBubbles</a> | <a href="https://github.com/NousResearch/hermes-agent">Hermes Agent</a> | <a href="https://github.com/modelcontextprotocol/typescript-sdk">MCP SDK</a> | <a href="https://github.com/lovell/sharp">sharp</a> | <a href="https://github.com/FFmpeg/FFmpeg">FFmpeg</a></sub>
</p>
