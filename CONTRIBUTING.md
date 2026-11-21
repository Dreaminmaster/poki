# Contributing

For details on branches, checks, and how releases work, see [AGENTS.md](AGENTS.md#contribute-code) and [docs/release-channels.md](docs/release-channels.md). Run `npm test` before you submit, and say in the pull request whether you also tested on a Simulator or a physical iPhone.

All participation in this project follows the [Code of Conduct](CODE_OF_CONDUCT.md).

## When to open an issue first

To fix a typo, a small bug, or a documentation gap, feel free to open a pull request right away.

To add a feature or make a large change, open an issue first and wait for a maintainer to confirm that it is welcome before writing the code. A large change is any of the following:

- A new feature
- A change to how Poki operates the phone, including input, taps, screen reading, stopping a task, or keeping a task alive in the background
- A change to the first-time setup flow
- A change to the main flow of the interface
- A change that touches 10 or more files

If you are not sure whether your change counts as large, open an issue and ask. A pull request for an unapproved large change may be closed without review, no matter how good the code is.

## Contributor levels

There are four contributor levels. Everyone starts at the first level, and you do not need anyone to vouch for you before opening a pull request.

| Level | How you get there | What you can do |
| --- | --- | --- |
| Contributor | Anyone. Fork the repository and open a pull request. | Open issues and pull requests. Until your first pull request is merged, please keep only one pull request open at a time. |
| Invited contributor | Have three or more pull requests merged, and receive an invitation from a maintainer. | Triage access to add labels and close issues. You cannot merge pull requests. |
| Core contributor | Make sustained contributions over time, and receive an invitation from a maintainer. | Listed in [CODEOWNERS](.github/CODEOWNERS) and in the Core contributors section of [Contributors](#core-contributors). |
| Maintainer | Repository owner. | Approve releases and change repository settings. |

Only maintainers can merge pull requests into `main`. Moving up a level is decided by maintainers based on the quality and consistency of your work.

## Contributors

### Co-creator

<!-- CO-CREATOR:START -->
<p align="center">
  <a href="https://github.com/ZhehanZhang"><img src="https://avatars.githubusercontent.com/u/67270559?v=4&size=320" width="160" height="160" alt="ZhehanZhang"/><br /><b>ZhehanZhang</b></a><br />
  The great co-creator of Poki.
</p>
<!-- CO-CREATOR:END -->

### Core contributors

<!-- CORE-CONTRIBUTORS:START -->
<table>
  <tbody>
    <tr>
      <td align="center" valign="top" width="33%"><a href="https://github.com/makirqi-alt"><img src="https://avatars.githubusercontent.com/u/295395617?v=4&size=240" width="120" height="120" alt="makirqi-alt"/><br /><sub><b>makirqi-alt</b></sub></a><br />Filed Poki's first issue, <a href="https://github.com/JosssphZhou/poki/issues/1">#1</a>, on iOS 18.6.2: screenshots worked, accessibility and touch did not, and the clear split made it easy to follow.</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/edge369"><img src="https://avatars.githubusercontent.com/u/63720633?v=4&size=240" width="120" height="120" alt="edge369"/><br /><sub><b>edge369</b></sub></a><br />Made Poki run on a router in <a href="https://github.com/JosssphZhou/poki/pull/14">#14</a>, so Telegram can drive the iPhone with the Mac powered off; <a href="https://github.com/JosssphZhou/poki/pull/15">#15</a>, <a href="https://github.com/JosssphZhou/poki/pull/17">#17</a> and <a href="https://github.com/JosssphZhou/poki/issues/19">#19</a> followed.</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/mawenhao1028"><img src="https://avatars.githubusercontent.com/u/70818670?v=4&size=240" width="120" height="120" alt="mawenhao1028"/><br /><sub><b>mawenhao1028</b></sub></a><br />Reported in <a href="https://github.com/JosssphZhou/poki/issues/6">#6</a> that usbmuxd listed no iPhone on macOS 27.2; Poki now says so plainly and why a helper stops early (<a href="https://github.com/JosssphZhou/poki/issues/59">#59</a>).</td>
    </tr>
    <tr>
      <td align="center" valign="top" width="33%"><a href="https://github.com/igc110"><img src="https://avatars.githubusercontent.com/u/241411380?v=4&size=240" width="120" height="120" alt="igc110"/><br /><sub><b>igc110</b></sub></a><br />Found why taps on a physical iPhone were slow in <a href="https://github.com/JosssphZhou/poki/issues/10">#10</a>; the fix that followed made them about a third faster.</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/carrotciallo"><img src="https://avatars.githubusercontent.com/u/69567867?v=4&size=240" width="120" height="120" alt="carrotciallo"/><br /><sub><b>carrotciallo</b></sub></a><br />Ported Poki to Linux and tested it on a physical iPhone over USB, LAN and Tailscale in <a href="https://github.com/JosssphZhou/poki/issues/16">#16</a>; the README now points to it.</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/guangtouge82"><img src="https://avatars.githubusercontent.com/u/269691899?v=4&size=240" width="120" height="120" alt="guangtouge82"/><br /><sub><b>guangtouge82</b></sub></a><br />Traced failing touches on a physical iPhone to a missing display service in <a href="https://github.com/JosssphZhou/poki/issues/18">#18</a>; Poki now says nothing was sent and points to prepare-device.</td>
    </tr>
    <tr>
      <td align="center" valign="top" width="33%"><a href="https://github.com/Dreaminmaster"><img src="https://avatars.githubusercontent.com/u/189544503?v=4&size=240" width="120" height="120" alt="Dreaminmaster"/><br /><sub><b>Dreaminmaster</b></sub></a><br />Fixed a corrupt cached route that aborted unrelated Agent tasks (<a href="https://github.com/JosssphZhou/poki/issues/21">#21</a>, <a href="https://github.com/JosssphZhou/poki/pull/22">#22</a>), then let the Agent reuse its post-action screen read in <a href="https://github.com/JosssphZhou/poki/pull/37">#37</a>.</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/PeterKingXu1s"><img src="https://avatars.githubusercontent.com/u/89392314?v=4&size=240" width="120" height="120" alt="PeterKingXu1s"/><br /><sub><b>PeterKingXu1s</b></sub></a><br />Reported in <a href="https://github.com/JosssphZhou/poki/issues/25">#25</a> that a natural-language stop request did not interrupt an iMessage task; Poki now replies to mid-task messages and points to /stop.</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/ScottH1122"><img src="https://avatars.githubusercontent.com/u/142722955?v=4&size=240" width="120" height="120" alt="ScottH1122"/><br /><sub><b>ScottH1122</b></sub></a><br />Reproduced two Agent bugs in <a href="https://github.com/JosssphZhou/poki/issues/27">#27</a> and <a href="https://github.com/JosssphZhou/poki/issues/28">#28</a>, then merged seven fixes and test repairs, from cancelled input locks (<a href="https://github.com/JosssphZhou/poki/pull/102">#102</a>) to invalid touch coordinates (<a href="https://github.com/JosssphZhou/poki/pull/136">#136</a>).</td>
    </tr>
    <tr>
      <td align="center" valign="top" width="33%"><a href="https://github.com/jiahuipaung"><img src="https://avatars.githubusercontent.com/u/70688286?v=4&size=240" width="120" height="120" alt="jiahuipaung"/><br /><sub><b>jiahuipaung</b></sub></a><br />Fixed in <a href="https://github.com/JosssphZhou/poki/pull/34">#34</a> a RemotePairing connection that died when the iPhone's LAN address changed (<a href="https://github.com/JosssphZhou/poki/issues/30">#30</a>); a real iPhone reconnected in 768 ms.</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/Zeno6898"><img src="https://avatars.githubusercontent.com/u/229920081?v=4&size=240" width="120" height="120" alt="Zeno6898"/><br /><sub><b>Zeno6898</b></sub></a><br />Field-tested the iPhone app over cellular and from Windows in <a href="https://github.com/JosssphZhou/poki/issues/35">#35</a> and <a href="https://github.com/JosssphZhou/poki/issues/40">#40</a>, which led to the Wi-Fi setup note (<a href="https://github.com/JosssphZhou/poki/issues/138">#138</a>); reported <a href="https://github.com/JosssphZhou/poki/issues/162">#162</a>.</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/scy7796"><img src="https://avatars.githubusercontent.com/u/282529358?v=4&size=240" width="120" height="120" alt="scy7796"/><br /><sub><b>scy7796</b></sub></a><br />Fixed taps that failed every time over RemotePairing from a Windows host in <a href="https://github.com/JosssphZhou/poki/pull/39">#39</a>; 5 of 5 taps then worked.</td>
    </tr>
    <tr>
      <td align="center" valign="top" width="33%"><a href="https://github.com/foshanfm"><img src="https://avatars.githubusercontent.com/u/24779370?v=4&size=240" width="120" height="120" alt="foshanfm"/><br /><sub><b>foshanfm</b></sub></a><br />Ran an insurance-terms check on a real iPhone over Tailscale in <a href="https://github.com/JosssphZhou/poki/issues/42">#42</a>; the report shaped clearer USB errors and a per-session transport switch.</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/xiaweiyi713"><img src="https://avatars.githubusercontent.com/u/208608622?v=4&size=240" width="120" height="120" alt="xiaweiyi713"/><br /><sub><b>xiaweiyi713</b></sub></a><br />Recorded demo videos of Poki driving a real iPhone, so new visitors can see what it does before installing anything.</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/fucknima"><img src="https://avatars.githubusercontent.com/u/18666223?v=4&size=240" width="120" height="120" alt="f&#42;&#42;&#42;&#42;&#42;&#42;&#42;"/><br /><sub><b>f&#42;&#42;&#42;&#42;&#42;&#42;&#42;</b></sub></a><br />Added OpenCode Go as a model account in the iPhone app in <a href="https://github.com/JosssphZhou/poki/pull/68">#68</a>, with its own Keychain credential and independent model choice.</td>
    </tr>
    <tr>
      <td align="center" valign="top" width="33%"><a href="https://github.com/owensn951954688"><img src="https://avatars.githubusercontent.com/u/312761798?v=4&size=240" width="120" height="120" alt="owensn951954688"/><br /><sub><b>owensn951954688</b></sub></a><br />Shared a full timeline of Runner pairing failing after 25 idle minutes in <a href="https://github.com/JosssphZhou/poki/issues/69">#69</a>; Poki Setup now points to Loopback and Pairing (<a href="https://github.com/JosssphZhou/poki/issues/70">#70</a>).</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/kira-ariaki"><img src="https://avatars.githubusercontent.com/u/257352493?v=4&size=240" width="120" height="120" alt="kira-ariaki"/><br /><sub><b>kira-ariaki</b></sub></a><br />Made batch calls report an ambiguous device instead of crashing (<a href="https://github.com/JosssphZhou/poki/pull/74">#74</a>), added POKI_MCP_DEVICE (<a href="https://github.com/JosssphZhou/poki/pull/75">#75</a>) and an optional per-task approval gate (<a href="https://github.com/JosssphZhou/poki/pull/77">#77</a>).</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/Purelite"><img src="https://avatars.githubusercontent.com/u/9334469?v=4&size=240" width="120" height="120" alt="Purelite"/><br /><sub><b>Purelite</b></sub></a><br />Fixed pairing setup sending people to the wrong Settings page, so the Developer Mode and UI Automation steps now open the right one (<a href="https://github.com/JosssphZhou/poki/pull/137">#137</a>).</td>
    </tr>
    <tr>
      <td align="center" valign="top" width="33%"><a href="https://github.com/heyallencao"><img src="https://avatars.githubusercontent.com/u/258265534?v=4&size=240" width="120" height="120" alt="heyallencao"/><br /><sub><b>heyallencao</b></sub></a><br />Fixed screen reads that ran past their call deadline in <a href="https://github.com/JosssphZhou/poki/pull/139">#139</a>, with a regression test for consistently slow runner responses.</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/Ryanwu316"><img src="https://avatars.githubusercontent.com/u/49024277?v=4&size=240" width="120" height="120" alt="Ryanwu316"/><br /><sub><b>Ryanwu316</b></sub></a><br />Brought two-app workspaces to iPhone Duo in <a href="https://github.com/JosssphZhou/poki/pull/354">#354</a>, so a task waits through rotation and resumes on the same app pair.</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/soloface"><img src="https://avatars.githubusercontent.com/u/62548950?v=4&size=240" width="120" height="120" alt="soloface"/><br /><sub><b>soloface</b></sub></a><br />Traced MCP 503 errors on a phone that showed online to a relay reconnect bug in <a href="https://github.com/JosssphZhou/poki/issues/311">#311</a>, with a reproducing test and a patch.</td>
    </tr>
    <tr>
      <td align="center" valign="top" width="33%"><a href="https://github.com/whiteluw"><img src="https://avatars.githubusercontent.com/u/86720151?v=4&size=240" width="120" height="120" alt="whiteluw"/><br /><sub><b>whiteluw</b></sub></a><br />Contributed <a href="https://github.com/JosssphZhou/poki/pull/326">#326</a> to avoid a 3D bear startup crash on iPhone.</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/cs50Mu"><img src="https://avatars.githubusercontent.com/u/4456781?v=4&size=240" width="120" height="120" alt="cs50Mu"/><br /><sub><b>cs50Mu</b></sub></a><br />Found in <a href="https://github.com/JosssphZhou/poki/issues/362">#362</a> that the Poki Setup macOS download only ran on Apple silicon; the universal build that followed also runs on Intel Macs.</td>
      <td align="center" valign="top" width="33%"><a href="https://github.com/mgkvibez"><img src="https://avatars.githubusercontent.com/u/198796435?v=4&size=240" width="120" height="120" alt="mgkvibez"/><br /><sub><b>mgkvibez</b></sub></a><br />Added a test in <a href="https://github.com/JosssphZhou/poki/pull/380">#380</a> that keeps payment checks ahead of message sending, so a Send money button in Mail still asks for approval.</td>
    </tr>
  </tbody>
</table>
<!-- CORE-CONTRIBUTORS:END -->

### Special contributors

<table>
  <tbody>
    <tr>
      <td align="center" valign="top" width="33%"><a href="https://github.com/yulunRyanw"><img src="https://avatars.githubusercontent.com/u/216360668?v=4&size=240" width="120" height="120" alt="yulunRyanw"/><br /><sub><b>yulunRyanw</b></sub></a><br />Sent a full set of interface designs for the 0.4.0 redesign, from the chat and Live Activity to Settings and a first run (<a href="https://github.com/JosssphZhou/poki/pull/250">#250</a>, <a href="https://github.com/JosssphZhou/poki/pull/256">#256</a> to <a href="https://github.com/JosssphZhou/poki/pull/268">#268</a>); they shaped the direction of the new interface.</td>
    </tr>
  </tbody>
</table>

### Thanks

Thanks to everyone who opened an issue or pull request. Your feedback and fixes make Poki better.

<!-- THANKS-WALL:START -->
<table>
  <tbody>
    <tr>
      <td align="center" valign="top" width="20%"><a href="https://github.com/ZhehanZhang"><img src="https://avatars.githubusercontent.com/u/67270559?v=4&size=160" width="80" height="80" alt="ZhehanZhang"/><br /><sub><b>ZhehanZhang</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/carrotciallo"><img src="https://avatars.githubusercontent.com/u/69567867?v=4&size=160" width="80" height="80" alt="carrotciallo"/><br /><sub><b>carrotciallo</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/cs50Mu"><img src="https://avatars.githubusercontent.com/u/4456781?v=4&size=160" width="80" height="80" alt="cs50Mu"/><br /><sub><b>cs50Mu</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/Dreaminmaster"><img src="https://avatars.githubusercontent.com/u/189544503?v=4&size=160" width="80" height="80" alt="Dreaminmaster"/><br /><sub><b>Dreaminmaster</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/edge369"><img src="https://avatars.githubusercontent.com/u/63720633?v=4&size=160" width="80" height="80" alt="edge369"/><br /><sub><b>edge369</b></sub></a></td>
    </tr>
    <tr>
      <td align="center" valign="top" width="20%"><a href="https://github.com/foshanfm"><img src="https://avatars.githubusercontent.com/u/24779370?v=4&size=160" width="80" height="80" alt="foshanfm"/><br /><sub><b>foshanfm</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/fucknima"><img src="https://avatars.githubusercontent.com/u/18666223?v=4&size=160" width="80" height="80" alt="f&#42;&#42;&#42;&#42;&#42;&#42;&#42;"/><br /><sub><b>f&#42;&#42;&#42;&#42;&#42;&#42;&#42;</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/guangtouge82"><img src="https://avatars.githubusercontent.com/u/269691899?v=4&size=160" width="80" height="80" alt="guangtouge82"/><br /><sub><b>guangtouge82</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/heyallencao"><img src="https://avatars.githubusercontent.com/u/258265534?v=4&size=160" width="80" height="80" alt="heyallencao"/><br /><sub><b>heyallencao</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/htx996"><img src="https://avatars.githubusercontent.com/u/95217139?v=4&size=160" width="80" height="80" alt="htx996"/><br /><sub><b>htx996</b></sub></a></td>
    </tr>
    <tr>
      <td align="center" valign="top" width="20%"><a href="https://github.com/igc110"><img src="https://avatars.githubusercontent.com/u/241411380?v=4&size=160" width="80" height="80" alt="igc110"/><br /><sub><b>igc110</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/iTry"><img src="https://avatars.githubusercontent.com/u/1381960?v=4&size=160" width="80" height="80" alt="iTry"/><br /><sub><b>iTry</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/jiahuipaung"><img src="https://avatars.githubusercontent.com/u/70688286?v=4&size=160" width="80" height="80" alt="jiahuipaung"/><br /><sub><b>jiahuipaung</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/kilingzhang"><img src="https://avatars.githubusercontent.com/u/17439300?v=4&size=160" width="80" height="80" alt="kilingzhang"/><br /><sub><b>kilingzhang</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/kira-ariaki"><img src="https://avatars.githubusercontent.com/u/257352493?v=4&size=160" width="80" height="80" alt="kira-ariaki"/><br /><sub><b>kira-ariaki</b></sub></a></td>
    </tr>
    <tr>
      <td align="center" valign="top" width="20%"><a href="https://github.com/lunar-me"><img src="https://avatars.githubusercontent.com/u/275556969?v=4&size=160" width="80" height="80" alt="lunar-me"/><br /><sub><b>lunar-me</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/makirqi-alt"><img src="https://avatars.githubusercontent.com/u/295395617?v=4&size=160" width="80" height="80" alt="makirqi-alt"/><br /><sub><b>makirqi-alt</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/mawenhao1028"><img src="https://avatars.githubusercontent.com/u/70818670?v=4&size=160" width="80" height="80" alt="mawenhao1028"/><br /><sub><b>mawenhao1028</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/mgkvibez"><img src="https://avatars.githubusercontent.com/u/198796435?v=4&size=160" width="80" height="80" alt="mgkvibez"/><br /><sub><b>mgkvibez</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/oasis979559-alt"><img src="https://avatars.githubusercontent.com/u/295108220?v=4&size=160" width="80" height="80" alt="oasis979559-alt"/><br /><sub><b>oasis979559-alt</b></sub></a></td>
    </tr>
    <tr>
      <td align="center" valign="top" width="20%"><a href="https://github.com/owensn951954688"><img src="https://avatars.githubusercontent.com/u/312761798?v=4&size=160" width="80" height="80" alt="owensn951954688"/><br /><sub><b>owensn951954688</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/PeterKingXu1s"><img src="https://avatars.githubusercontent.com/u/89392314?v=4&size=160" width="80" height="80" alt="PeterKingXu1s"/><br /><sub><b>PeterKingXu1s</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/Purelite"><img src="https://avatars.githubusercontent.com/u/9334469?v=4&size=160" width="80" height="80" alt="Purelite"/><br /><sub><b>Purelite</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/Ryanwu316"><img src="https://avatars.githubusercontent.com/u/49024277?v=4&size=160" width="80" height="80" alt="Ryanwu316"/><br /><sub><b>Ryanwu316</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/ScottH1122"><img src="https://avatars.githubusercontent.com/u/142722955?v=4&size=160" width="80" height="80" alt="ScottH1122"/><br /><sub><b>ScottH1122</b></sub></a></td>
    </tr>
    <tr>
      <td align="center" valign="top" width="20%"><a href="https://github.com/scy7796"><img src="https://avatars.githubusercontent.com/u/282529358?v=4&size=160" width="80" height="80" alt="scy7796"/><br /><sub><b>scy7796</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/soloface"><img src="https://avatars.githubusercontent.com/u/62548950?v=4&size=160" width="80" height="80" alt="soloface"/><br /><sub><b>soloface</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/wanghao-SunSky"><img src="https://avatars.githubusercontent.com/u/73684879?v=4&size=160" width="80" height="80" alt="wanghao-SunSky"/><br /><sub><b>wanghao-SunSky</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/whiteluw"><img src="https://avatars.githubusercontent.com/u/86720151?v=4&size=160" width="80" height="80" alt="whiteluw"/><br /><sub><b>whiteluw</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/windywendyday"><img src="https://avatars.githubusercontent.com/u/65647922?v=4&size=160" width="80" height="80" alt="windywendyday"/><br /><sub><b>windywendyday</b></sub></a></td>
    </tr>
    <tr>
      <td align="center" valign="top" width="20%"><a href="https://github.com/xiaweiyi713"><img src="https://avatars.githubusercontent.com/u/208608622?v=4&size=160" width="80" height="80" alt="xiaweiyi713"/><br /><sub><b>xiaweiyi713</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/yulunRyanw"><img src="https://avatars.githubusercontent.com/u/216360668?v=4&size=160" width="80" height="80" alt="yulunRyanw"/><br /><sub><b>yulunRyanw</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/zcyoung2000"><img src="https://avatars.githubusercontent.com/u/62181891?v=4&size=160" width="80" height="80" alt="zcyoung2000"/><br /><sub><b>zcyoung2000</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/Zeno6898"><img src="https://avatars.githubusercontent.com/u/229920081?v=4&size=160" width="80" height="80" alt="Zeno6898"/><br /><sub><b>Zeno6898</b></sub></a></td>
      <td align="center" valign="top" width="20%"><a href="https://github.com/zqy5608"><img src="https://avatars.githubusercontent.com/u/14949471?v=4&size=160" width="80" height="80" alt="zqy5608"/><br /><sub><b>zqy5608</b></sub></a></td>
    </tr>
  </tbody>
</table>
<!-- THANKS-WALL:END -->

### Star History

<a href="https://www.star-history.com/?repos=JosssphZhou%2Fpoki&type=date&legend=top-left">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=JosssphZhou/poki&type=date&theme=dark&legend=top-left">
    <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=JosssphZhou/poki&type=date&legend=top-left">
    <img alt="Star History chart" src="https://api.star-history.com/chart?repos=JosssphZhou/poki&type=date&legend=top-left">
  </picture>
</a>

## AI assistance

You are welcome to use AI tools. The pull request template asks you to include one line:

> AI assistance: None, Claude Code, Codex, or Other. I have reviewed and understand these changes.

List the tool you used, and confirm that you have read and understood the entire change. Be ready to explain any line during review.

## How to open a pull request

You do not have write access to `JosssphZhou/poki`, so `git push` to it fails with `permission denied`. That is expected. Push to your own fork and open the pull request from there.

With the GitHub CLI, from your clone with the branch already made:

```sh
gh repo fork --remote            # creates your fork, adds it as origin, renames the old origin to upstream
git push -u origin <branch>
gh pr create --base main
```

Without it: click **Fork** on GitHub, then

```sh
git remote add fork https://github.com/<you>/poki.git
git push -u fork <branch>
```

and open a pull request from that branch into `main` of `JosssphZhou/poki` on the website.

Before you open it, run `npm test` and fill in the [pull request template](.github/PULL_REQUEST_TEMPLATE.md): what changes and how you tested it. The `PR checks` workflow must pass.

By submitting a contribution, you release it under the [AGPL-3.0-only license](LICENSE). You confirm this once: on your first pull request, Poki Repo Bot asks you to agree to the [Poki Contributor Agreement](CONTRIBUTOR_AGREEMENT.md) by commenting `I agree to the Poki Contributor Agreement` from your own account. That covers your later pull requests too, and the `Contributor agreement` status on the pull request turns green.

Use third-party code only if its license is compatible with AGPL-3.0-only. Keep the original copyright notice and list the code in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Do not commit device screenshots, clipboard contents, pairing records, passcodes, or tokens.
