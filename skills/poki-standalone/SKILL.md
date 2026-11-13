---
name: poki-standalone
description: Configure and verify Poki running on an iPhone without a connected computer, including signing, local developer services, pairing, a self-hosted relay and a remote MCP client. For a normal iPhone app installation or update, use install-poki first; for the Mac MCP server, use the repository installation guide.
license: AGPL-3.0-only
---

# Run Poki independently on an iPhone

For a first installation, an update, or a failed in-app update, read [install-poki](../install-poki/SKILL.md) first. It owns version checks, renewal and preservation requirements. If this skill was copied alone, read `skills/install-poki/SKILL.md` in the checkout. Do not replace an existing custom-signed or built-in-connection app with Poki Setup's external build.

For an authorized custom setup, read sections 1 and 2 of the [operations guide](references/operations.md), then follow the applicable sections. Use section 8 for signing or pairing failures.

## Procedure

1. **Identify the build and phone.** Check the checkout, branch, uncommitted changes and installed version. Confirm the target phone and whether someone is using it. Only one operator controls a shared phone at a time; release control while waiting for the user. Done when each result can be tied to one phone and one commit.
2. **Choose the local connection.** Preserve the user's existing VPN when it supports loopback. In Poki 0.4.0, open Settings from the conversations drawer, then Automation > Setup > Local Connection. Choose the VPN's instructions under Use Your Proxy App. LocalDevVPN has its own page. A built-in connection requires a separately signed build with the matching entitlement; Poki Setup strips that extension. Done when developer services answer and the user's existing internet route still works.
3. **Prepare the app and pairing.** Follow sections 3 and 4. Check nested signatures, Developer Mode and UI Automation. Normally install only Poki. Install Poki Runner only for an explicitly requested legacy Runner setup. The user enters passcodes and pairing codes on the device. Done when pairing and permissions are ready and a real screen read or authorized action succeeds. An XCTest session log alone does not prove native automation on iOS 27.
4. **Connect the relay.** Deploy a separate relay in the authorized account. Enter it in Settings > External Agents > Relay, then use Add Agent for this client. Keep the connector URL in private client configuration. Done when the relay is ready and a real MCP client receives a phone reply.
5. **Connect the remote client.** Follow section 6 using the client's current supported remote MCP configuration. A connected plugin card alone is not success. Done when a task from the selected cloud environment calls the connector and produces the intended phone result.
6. **Verify and report.** Confirm USB is disconnected, then start a new task. Record basic operation, approvals and stability separately, with the actual commit, network and redacted evidence. Done when the authorized checks have results and all untested cases are named. Merge or publish only within the task's authorization.

## Evidence and privacy

Keep relay addresses, connector URLs, tokens, pairing records, account details and device identifiers in necessary private configuration. Review logs and images before sharing. Avoid connection settings in demonstration recordings.

`10.7.0.1` is the phone's local loopback endpoint, not a user's server address. Verify protocol tools, tools exposed by the client, and the result on the phone separately. Opening one app proves only that operation.

Report untested lock recovery, cellular use, long background sessions and Live Activity approvals as untested. Section 9 records a historical verification boundary; it cannot replace acceptance on a new build. After a signing, version or connection change, repeat only the affected checks. Documentation editing does not authorize phone operations.
