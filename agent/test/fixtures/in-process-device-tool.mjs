// Load before the Agent or MCP modules capture the tool path from the environment.
// These tests use a local MCP fixture; Node only satisfies the executable check.
process.env.IDEVICE_TOOLS = process.execPath;
