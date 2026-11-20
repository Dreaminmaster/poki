# Install Poki on iPhone from source with your agent

Copy the whole block below into a coding agent that can run commands on your Mac. This builds the Poki iPhone app with Xcode and signs it with your Apple developer team.

~~~text
Build Poki from source on my Mac and install it on my iPhone. Use the scripts/phone.sh in the Poki checkout.

## Get my choices

Ask once for the missing choices below. Reuse any answers I already gave you. Discover tool versions and device IDs yourself. If a choice depends on a check, tell me what you found before asking me to choose.

- The Poki checkout to use, or where to clone https://github.com/JosssphZhou/poki.git. Use the revision I give you, or main for a new clone.
- The iPhone to install on if more than one is connected. Ask whether this is a fresh install or an update of an existing source build.
- My signing team and type: free Personal Team or paid Apple Developer Program. Ask for the team ID only if you cannot determine it in Xcode. For a paid team, ask whether I want the external connection or the built-in connection. Use the external connection by default.
- My reverse-DNS bundle ID prefix for a fresh install, such as com.example. Use com.example.poki for the app and group.com.example.poki for the App Group. For an update, reuse the app's exact team, bundle ID, App Group, and build variant. Ask me to confirm any signing value you cannot verify before you install.

Keep my existing checkout changes and app data. If the installed copy was signed with a different team or identifier, explain that a different bundle ID creates a separate app with separate data. Ask before proceeding. Keep passwords, verification codes, device passcodes, and model credentials out of chat and logs. Let me enter them in Xcode or on the iPhone when prompted.

## Check the Mac and iPhone

Run the checks before asking me to change anything. Guide me through missing steps only.

1. Run xcodebuild -version and xcodebuild -version -sdk iphoneos SDKVersion. For a simulator build, use iphonesimulator in the SDK check.

   Use full Xcode 26 or later with the iOS 26 SDK or later, even for an iPhone running iOS 18. For iPhone Duo, use Xcode 27.1 or later with the iOS 27.1 SDK or later. Check that Xcode also supports my iPhone's iOS version. If Xcode or the SDK is too old, stop and help me install or select a supported Xcode before building.

   If setup is incomplete, have me open Xcode, finish first launch, and install the iOS platform. If the wrong Xcode is selected, use DEVELOPER_DIR for this terminal or ask me to choose the right Xcode in Settings > Locations > Command Line Tools.
2. Check for Git, Python 3, XcodeGen, rustup, and the stable Rust toolchain. Install missing tools with my approval. If I use Homebrew, brew install xcodegen installs XcodeGen. Add the device target with rustup target add --toolchain stable aarch64-apple-ios. For a simulator check, also install an iOS Simulator runtime through Xcode and add the aarch64-apple-ios-sim Rust target. The script builds for Apple silicon on the simulator.
3. Check Xcode > Settings > Accounts for the signing team. If it is missing, let me add my Apple Account and handle any agreement or verification prompt. A Personal Team uses the external build. Apple allows up to three free-provisioned apps per device, and each development profile expires after seven days. To renew, rerun the same install command with the same identifiers and team. If the iPhone is at its limit, let me decide which app to remove.
4. Have me connect the iPhone by USB and unlock it if needed. Let me accept Trust This Computer on the iPhone. In Xcode's Device Hub or xcrun devicectl list devices, match the selected iPhone to its hardware UDID and check that Xcode supports its iOS version. If Developer Mode is off, have me enable it in Settings > Privacy & Security > Developer Mode. Wait for me to restart and confirm on the iPhone. If the toggle is missing, first let Xcode finish pairing and preparing the iPhone.

## Sign and install

Use PokiExternal.xcodeproj for the external connection. A team with Network Extensions provisioned for packet-tunnel-provider can choose Poki.xcodeproj for the built-in connection. Both use the Poki scheme.

Use automatic development signing with the same team for Poki and PokiWidgets. PokiWidgets uses the app bundle ID plus .widgets. Use the same App Group for the app and widget so Live Activity thumbnails and approval actions can work. If signing needs help, open the generated project and add or select that App Group under Signing & Capabilities for both targets. For the built-in connection, also sign PokiTunnel with the same team, with the app bundle ID plus .tunnel. Poki and PokiTunnel both need profiles that include the packet tunnel entitlement. If Xcode rejects a capability, report the target and the signing error and help me resolve it with my team. Keep the required entitlements.

From the repository root, run:

    scripts/phone.sh device IPHONE_UDID TEAM_ID BUNDLE_ID APP_GROUP

Append --built-in when the team and our choice call for the built-in connection. Substitute the values we confirmed. Xcode can register the selected iPhone and create or update the development profiles for those identifiers. Ask me to take over for any account or Keychain prompt. If iOS says the developer is untrusted after installation, have me open Settings > General > VPN & Device Management, select the matching developer, and tap Trust if offered. Retry with the same arguments. Keep the iPhone unlocked during installation and launch.

The script prepares the pinned PokiLauncher dependency, builds the Rust library, generates Xcode assets and the project, builds and installs Poki, opens it, and checks that the launched process still exists after five seconds. For an early exit it uses devicectl to look for and copy a new Poki crash report. If a report is still being written, check xcrun devicectl device info files --device IPHONE_UDID --domain-type systemCrashLogs again. Keep raw logs and crash reports local. Report the failing step and a redacted error if anything stops.

For a simulator check before installing on the phone, boot a dedicated iPhone simulator and pass its exact UUID to scripts/phone.sh simulator SIMULATOR_UDID. Confirm Poki's first screen opens. Simulator success covers build and launch for the simulator.

## Confirm what works

Have me confirm that Poki is visible on the intended iPhone. On iOS 27 and later, follow Poki's setup for on-device pairing. On earlier versions, use Poki Setup's pairing option on the Mac and import the pairing file in Poki. Keep the pairing file private. For an external build, follow Poki's connection instructions to route 10.7.0.1 back to the iPhone with LocalDevVPN or another supported VPN app. For the built-in build, accept the VPN configuration prompt for Poki's local connection.

On iOS 18 through 26, the default XCTest path requires the UI Automation switch in Settings > Developer. Enable UI Automation if the selected automation path requires it. If Poki asks for Automation Mode, let me confirm and enter the passcode myself. The default native services path on iOS 27 and later uses a different automation connection. Follow the checks shown in Poki. If I want to run a task, let me connect my own model account in Poki and approve the specific task first.

Tell me which revision, build variant, and iPhone you used, how long each script step took, and what you verified. If I stopped after launch, mark pairing, the local connection, automation, and model setup as unverified. A running process only proves that Poki opened and stayed up for the startup check.
~~~

See the [Poki build and signing guide](../native/ios-app/README.md#build), the [iPhone setup guide](iphone-guide.md), and [Apple's Personal Team limits](https://developer.apple.com/help/account/basics/about-your-developer-account/).
