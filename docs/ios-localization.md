# iOS UI language

Settings › Language offers **Follow System** (the default) and the localizations bundled with
this build. The initial translations are English, Simplified Chinese and Traditional Chinese.
Follow System uses `Bundle.main.preferredLocalizations`, so iOS's per-app language setting takes
precedence over the first language in the device's global list. An unsupported saved selection
falls back to the effective app language. iOS can relaunch the app when its per-app language changes.

An explicit selection updates Poki-owned screens immediately. `uiLanguage` lives in UserDefaults
and the existing SettingsVault backup. The effective language is mirrored into the existing App
Group for the widget extension. A quiet content update refreshes an existing Live Activity without
starting another activity or changing its automation/approval state. New notification content and
notification action labels use the selected language; already delivered notification content keeps
its creation-time language. System-owned permission prompts and pickers remain controlled by iOS.

## Implementing display text

- Use native SwiftUI localized `Text`, `Label`, `Button`, etc. The root supplies the selected locale
  and writing direction. Never recreate the root, AppModel, ChatModel or navigation path on a
  language change.
- For programmatic UI strings, use
  `AppLocalization.text(LocalizedStringResource("Ready", table: "Status"))`. A resource's locale
  chooses the translation as well as interpolation formatting. `String(localized:locale:)` alone
  does **not** change the translation lookup. Keep literal resources at call sites for Xcode's
  String Catalog extraction. The shorter `AppLocalization.text("General")` works for literal keys.
- Resolve navigation titles explicitly with `AppLocalization.text`, since a cached localized
  navigation title can otherwise retain its previous language. Do not translate user-chosen titles.
- Existing runtime status keys use `AppLocalization.bundle`. Unknown keys fall back to their original
  text. This is for known Poki/runtime status vocabulary, not for matching or translating user input.
- UI date/list formatting uses `AppLocalization.locale`; the user's region and locale conventions
  are retained. Machine timestamps and protocol values keep their original formats.
- Body fonts remain native. Prominent text uses Geist for English and system fonts for other
  languages, preserving Dynamic Type and glyph coverage. Existing navigation bars update their
  fonts in place, without replacing controllers.

User/model messages, task plans, user-supplied app/account names, diagnostic logs and recorded conversation text
remain content in their original language. Only the current untouched introduction has retained
in-memory UI identity and can be reworded on a language change; its entry IDs, timestamps and session
ID stay intact. Opening a saved conversation does not translate its history. UI language does not
alter speech recognition, model prompts, provider routing, credentials or approval decisions.

## Adding a language

1. Add translations to the existing `Shared/Localizable.xcstrings`, `Shared/Status.xcstrings`,
   `Shared/LiveActivity.xcstrings`, `Poki/Chat/Chat.xcstrings` and `Poki/InfoPlist.xcstrings` catalogs.
   English source keys are the fallback; a missing explicit English value is not a missing translation.
2. Declare the shipped language in `CFBundleLocalizations` in `project-base.yml`. XcodeGen compiles
   the same shared catalogs into the app and widget. The Language page discovers the resulting bundle
   localizations; no new preference enum, settings row or translation engine is needed.
3. Review machine-assisted drafts, especially permission, approval, deletion and payment wording.
   Review plural/interpolation variants and accessibility labels. Adding a locale does not translate
   its contents automatically.
4. Check the app and widget at large text sizes and narrow widths. RTL follows the selected language
   in the root; a new RTL translation still needs layout review before shipping. Device-controlled
   surfaces should also be checked through iOS's per-app language setting.

## Resolution cache

Supported bundle languages are discovered once. Language, formatting locale and resource bundle
share a lock-protected snapshot, rebuilt when the selected preference changes or the system emits
its current-locale change notification. App reads still observe the language preference so SwiftUI
updates remain live. Extensions re-read the shared `effectiveUILanguage` key before using the cache;
this detects preference changes without depending on cross-process defaults notifications.

`LocalizationCacheTests` checks reuse across repeated lookups, preference changes, and system
language/region changes. This removes repeated resolution work; it does not establish a measured
frame-time improvement.

## Focused verification

Generate the intended signing variant with XcodeGen, then run the `Poki` scheme on an **existing**
Simulator with `-only-testing:PokiTests/LanguageTests`. The tests cover native resource resolution,
system/unsupported language matching, region preservation, shared preferences, activity/approval
state, untouched introduction identity, and language changes during a local scripted model request.
`GreetingTests` and `LiveActivityTests` provide nearby regressions; no live model account is needed.

In Settings › Language, switch English → 简体中文 → 繁體中文 → Follow System. Check the active navigation title,
section labels, Settings back navigation, Home greeting/suggestions/status, and the message field's
accessibility label. Relaunch with an explicit choice, then with Follow System under another iOS app
language. Keep a draft while opening Settings and verify it remains when closing Settings. Separately
check Lock Screen/Dynamic Island and delivered notification actions on a signed physical device;
Simulator builds and state tests do not establish that device-level presentation result.
