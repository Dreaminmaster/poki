# Local developer connection

Poki must work without Shadowrocket or another paid proxy app. The default build embeds a local
packet tunnel. The owner opens Setup, enables the local connection, and approves iOS's VPN prompt.
Poki then checks the phone's developer services before marking this setup step complete. Cloudflare
remains the MCP relay; it cannot provide the phone's local developer connection.

## Design

Two shapes were considered: require every user to install a helper such as LocalDevVPN, or embed
the connection in Poki. The embedded connection is the default because it keeps setup in one app.
An external-connection build remains necessary for signing without Network Extensions and users
who need to keep a compatible existing VPN. No VPN profile is changed, and no tunnel started, automatically on app launch.
Setup offers the external connection first when a supported VPN app is installed, including Karing.
The user can explicitly choose the built-in fallback. Karing's own `loopback_address` can supply
the reflection while continuing to proxy internet traffic; Poki must keep its tunnel off in this mode.
This shares one VPN rather than trying to run two packet tunnels at once.

The app calls `LoopbackTunnel.connect()` only after the owner enables the built-in connection or
explicitly starts a session with that method selected. While a session is on, `LoopbackTunnel` also
dials its own tunnel again after it failed or dropped (`ReconnectPlan`: 1, 2, 4, 8, 16, 30, 30, 30 s,
then it stops). It never does so after the owner ended it, after another VPN took the packet tunnel,
or while another VPN is detected (`OtherVPN`, best effort: a VPN that sets no proxy, such as Tailscale, may not be detected); it says so in the app instead. `refresh()` only reads Poki's saved profile;
`disconnect()` only stops that profile. Its provider id is read from the embedded extension, so a
signing tool's rewritten identifiers are used. Switching methods is disabled during pairing, an
active session, or a pending configuration change. Errors give the owner an external fallback.

The extension calls `LoopbackNetworkSettings.make()` and passes packets through
`LoopbackPacket.reflect(Data) -> Data?`. These are production interfaces in the small `PokiLoopback`
package, also exercised directly on macOS. `PokiTunnel` owns the serial packet read/write lifetime.
PokiCore and the Rust launcher retain their existing interfaces.

The route contract is:

- Interface `10.7.0.2/32`; sole included destination `10.7.0.1/32`; default route excluded.
- IPv4 TCP only, including dynamic developer-service ports. No DNS, IPv6 or proxy settings.
- Validate header lengths, total length, endpoint addresses and TCP header length. Drop fragments.
  TCP uses the tunnel's MTU of 1500; fragmented packets are outside this interface's contract.
- Swap source and destination addresses, preserving ports, TCP payload and checksums. Exchanging
  addresses preserves the IPv4 and TCP one's-complement checksum sums.
- No packet contents are logged, stored or sent to an external server. Packet-write failure stops
  the tunnel rather than reporting a working connection.

Saving a configuration and VPN Connected indicate tunnel status only. The setup step passes only
when RemotePairing (`49152`, or the port its Bonjour record names once iOS has moved it) or
lockdown (`62078`) accepts a TCP connection through `10.7.0.1`.

## Signing and distribution

`native/ios-app/project.yml` includes `project-base.yml` and adds `PokiTunnel`. Both the app and
tunnel require `com.apple.developer.networking.networkextension = [packet-tunnel-provider]` in
matching provisioning profiles. The app and widget also require matching App Groups for approvals.
Do not remove these capabilities to make a build sign and then describe it as equivalent.

`project-external.yml` includes the same base without the tunnel or its entitlement. CI builds both,
checks the embedded extensions, checks that xcodebuild gave the app and all extensions the release
version, and packages two IPAs. The signing-entitlements archive identifies the capabilities for each build.
The AltStore example uses the external build; it is not a claim of supported free-account approvals.

A free Personal Team cannot be assumed to provision Network Extensions. A properly provisioned
paid team can test a development/ad-hoc build; production distribution remains a separate decision.
See [Apple's manager/entitlement requirements](https://developer.apple.com/documentation/networkextension/netunnelprovidermanager)
and [SideStore's explanation of its App Store helper](https://github.com/SideStore/SideStore/blob/develop/README.md).

Another ordinary packet-tunnel VPN cannot be assumed to coexist with this one. Existing compatible
proxy apps can provide their own loopback instead. Personal VPN and enterprise VPN are distinct
in Apple's configuration model; compatibility must be measured for the actual combination.

## Set Up the Local Connection (the app's page)

The Setup item is named "Set Up the Local Connection". It shows whether 10.7.0.1 answers (two
ports are tried together, and a second 3 s round runs before the state leaves Working), a "Check
Again" button, and one row per proxy app that says only what Poki can know: Chosen or Installed.
Which app the loopback comes from cannot be told from inside Poki, so no per-app working state is
shown.

### Shadowrocket

Shadowrocket has its own switch for the route: Settings › Other › "Include Route 10.7.0.1/32"
(test build 2.2.91, reported working in 2.2.93). A module or a `[General]` line does not turn it
on. After changing it, disconnect and connect again, on Wi-Fi. The app's Shadowrocket page lists
these steps and, when nothing answers, what to check next. On iOS 18.7.7 the route was reported
never to appear (issue 124).

### Cellular connections and automation

Internet access, the local developer connection, and an automation session are separate.
A VPN reporting Connected does not prove that either developer port accepts a connection.
A TCP connection does not prove that RemotePairing, its dynamic tunnel listener, or RSD works.

The current product code uses the in-process XCTest session by default. Its launcher first opens
the local developer connection, then checks the developer image. When that connection fails at TCP
connect and the image is already mounted on the phone, the launcher reports `running` with code
`local_ddi` instead of waiting for the network. The status keeps the connection error (refused, no
route, or timed out), and the app writes it to its activity log. The app passes the launcher the
file it checks for the mounted image (`ddi_marker`). The app then opens its own XCTest session, which
needs no loopback. Automation counts as ready only after that session opens. The hand-over does not
check the pairing, so it does not update the pairing state. The signer still needs the loopback.
If the local open fails, Home says that the session did not open, with its code, and the launcher
tries the normal path once when the loopback answers again.
That return also checks the pairing and lets the signer retry, as before.

These steps still need the loopback, so on cellular they show "This step needs Wi-Fi. Connect and
try again.":

- Preparing a renewal or an update.
- Installing a prepared build.
- Mounting the developer image for the first time after the phone restarts.

The preserved `dev/esp-409-preserve-030` branch has a different design. It includes
`AutomationChooser`, native services, and its own mounted-image fallback. Those features are not
present in the current product code.

The local fallback adapts [PR #91](https://github.com/JosssphZhou/poki/pull/91) by Zeno6898.
[Its field report](https://github.com/JosssphZhou/poki/issues/35#issuecomment-6735040996) shows a
configured iPhone using cellular with no working loopback. That report covers an older build, so
the integrated build needs its own device check. [PR #84](https://github.com/JosssphZhou/poki/pull/84)
retains an automation session through idle and adds owner pause and resume. It needs a prepared
session and does not make an unavailable developer endpoint reachable. When integrating #84, keep
first-open passcode consent and explicit owner pause behavior. Do not use automation readiness as
proof that pairing or renewal is ready.

[Earlier Shadowrocket measurements](https://github.com/JosssphZhou/poki/issues/35#issuecomment-6705290849)
stopped at TCP connect on cellular. They also found a route to 10.7.0.1 after switching networks.
The reported localhost rejection is a different connection, so it does not establish the exact
server-side cause on the reflected address. Neither those results nor this app's path monitor
establish a universal iOS ban on cellular loopback.

For a failed local connection, connect to Wi-Fi, reconnect the selected local connection, and
retry. Test Wi-Fi enabled without an associated network separately; enabling the radio alone is
not a verified workaround. [SideStore's JIT guide](https://docs.sidestore.io/docs/advanced/jit)
describes starting a VPN, using Airplane Mode, and returning to cellular. That is an upstream
workaround, not verified Poki support. It can interrupt internet access needed for a relay or
Apple signing. The earlier Shadowrocket test did not succeed with cellular temporarily disabled.

## Acceptance

Run `swift test --package-path native/ios/PokiLoopback`. The three tests protect distinct contracts:
TCP conversation reflection, rejection of out-of-scope/malformed packets, and actual SDK network
settings that leave DNS/IPv6/default internet routing alone. No alternate packet implementation or
test-only production export is used. The packet and route tests failed against the new feature's
empty scaffold, not against the original branch, which had no such module. The rejection test is a
new data-protection test, not an existing-branch regression test.

Unsigned device builds and Simulator screenshots can establish packaging and UI behavior only.
Before claiming this works on an iPhone, complete section 1 and then sections 2–6 of
`device-test-checklist.md` on the designated, locked test device. Include first consent, live service
access, denied consent, restart, background/lock survival, Wi-Fi/cellular recovery, external VPN
coexistence and stop. Simulator VPN startup must report that a physical iPhone is required.

The standalone launcher binds the runner's HTTP and MJPEG listeners to `127.0.0.1`; the loopback
tunnel remains limited to the developer-service routes above and does not expose port 8100.
