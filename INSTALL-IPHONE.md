# Install or update the Poki iPhone app (for agents)

Use the agent skill [skills/install-poki/SKILL.md](skills/install-poki/SKILL.md). Read it and choose its first-install or update branch before running a command. First installation uses `node bin/install-iphone.mjs run --json`. Updating an existing app first checks its version, channel and signing identity. It is the backup when the iPhone cannot download an in-app update from GitHub.

Keep the existing app and its data. Poki Setup cannot preserve every custom signing or extension setup; the skill names the cases that must stop. Finish by reading the version and build on the iPhone and explaining signing renewal. A successful installer exit alone is not completion.

To keep it for later sessions, copy the whole `skills/install-poki` folder into your client's skill folder:

- Claude Code: `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/install-poki`
- Codex: `${CODEX_HOME:-$HOME/.codex}/skills/install-poki`

The skill runs the installer from a Poki checkout; it clones one when there is none.
