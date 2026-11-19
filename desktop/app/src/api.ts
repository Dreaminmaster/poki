// The commands the Rust side offers, typed.
import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";

export type Failure = { kind: string; message: string };
export type Progress =
  | { job: string; kind: "step"; id: string; title: string }
  | { job: string; kind: "part"; id: string; fraction: number; detail?: string | null }
  | { job: string; kind: "note"; id: string; text: string }
  | { job: string; kind: "waiting"; id: string; text: string }
  | { job: string; kind: "done"; id: string; detail?: string | null };

export type Link = { kind: "usb" } | { kind: "muxed"; address: string } | { kind: "wifi"; address: string };
export type Facts = { udid: string; name: string; product_type: string; ios: string; build: string; developer_mode: boolean | null; paired_with_this_computer: boolean; can_pair_on_device: boolean; wifi_address: string | null };
export type BuildRef = { artifact_id: number; run_id: number; run_number: number; workflow: string; branch: string; sha: string; pr?: number | null };
export type Record_ = { udid: string; phone_name: string; ios: string; apple_id: string; team_id: string; team_name: string; team_is_free: boolean; bundle_id: string; version: string; build: string; release_tag: string; signed_at: number; profile_expires_at: number; last_error: string | null; pairing_handed_off: boolean; test_build?: BuildRef | null };
export type PhoneRow = { phone: { udid: string; link: Link }; facts: Facts | null; error: string | null; record: Record_ | null };
export type Anisette = { kind: "system" } | { kind: "remote"; url: string };
export type Account = { signed_in: boolean; needs_reauth?: boolean; apple_id: string | null; name: string | null; team_id: string | null; password_kept: boolean; anisette: Anisette; pending_factor: "trusted_device" | "sms" | null };
export type Team = { team_id: string; name: string; kind: string; is_free: boolean };
export type Handoff = { link: string; inline_link: string; url: string; sha256: string; host: string; port: number; qr_svg: string; inline_qr_svg: string };
export type InstallResult = { record: Record_; notes: string[]; handoff: Handoff | null };
export type Deployed = { account_id: string; account_name: string; address: string; first_deploy: boolean; deployed_at: number; phone_link: string; worker_sha256?: string | null; worker_source?: string | null };
export type WorkerStatus = { source: string; download_url: string; guide_url: string; sha256: string; deployed_sha256: string | null; update_available: boolean };
export type CfAccount = { id: string; name: string };
export type Check = { at: number; ok: boolean; relay_ok: boolean; phone_online: boolean; tools: string[]; detail: string };
export type Connector = { name: string; url: string; added_at: number; last_check: Check | null };
export type AppInfo = { version: string; os: string; arch: string; data_dir: string; can_use_system_anisette: boolean };
export type ChannelId = "stable" | "beta" | "alpha" | "pre-alpha";
export type UpdateInfo = { current: string; latest: string | null; url: string | null; asset_url?: string | null; asset_name?: string | null; newer: boolean; source: "r2" | "github"; source_notice: string | null; channel?: ChannelId };
export type Release = { tag: string; version: string; build: string; published_at: string; ipa_name: string; source: "r2" | "github"; source_notice: string | null; channel?: ChannelId };
export type ChannelInfo = { id: ChannelId; title: string; selected: boolean; latest: Release | null };

// Developer: the GitHub sign-in and test builds from GitHub Actions.
export type DevPrefs = { only_mine: boolean; branch: string | null; with_pr_only: boolean; auto_download: boolean; auto_install: boolean; auto_install_udid: string | null; keep_on_renew: boolean; close_without_asking: boolean };
export type DevState = { signed_in: boolean; login: string | null; source: "github" | "cli" | "token" | null; cli_available: boolean; can_sign_in: boolean; prefs: DevPrefs; synced_run: number | null; downloads_bytes: number; repo: string };
export type GithubSignIn = { device_code: string; user_code: string; verification_uri: string; interval: number; expires_in: number };
export type PullRef = { number: number; title: string; url: string; state: string; draft: boolean };
export type TestBuild = { state: "ready" | "building" | "expired"; run_id: number; run_number: number; run_attempt: number; workflow: string; branch: string; sha: string; title: string; actor: string | null; event: string; run_url: string; created_at: string; pr: PullRef | null; artifact_id: number | null; artifact_name: string | null; size: number; expires_at: string | null; downloaded: boolean };
export type TestBuildListing = { builds: TestBuild[]; total: number; branches: string[]; login: string | null; checked_at: number };

/** What the install keeps in the device's record, so renewals sign the same build again. */
export function buildRef(b: TestBuild): BuildRef | null {
  if (b.artifact_id == null) return null;
  return { artifact_id: b.artifact_id, run_id: b.run_id, run_number: b.run_number, workflow: b.workflow, branch: b.branch, sha: b.sha, pr: b.pr?.number ?? null };
}

export const api = {
  appInfo: () => invoke<AppInfo>("app_info"),
  phones: () => invoke<PhoneRow[]>("phones"),
  pair: (udid: string) => invoke<void>("pair", { udid }),
  sharePairing: (udid: string) => invoke<Handoff>("share_pairing", { udid }),
  stopSharing: () => invoke<void>("stop_sharing"),
  devmode: (udid: string) => invoke<boolean>("devmode", { udid }),
  account: () => invoke<Account>("account"),
  signIn: (appleId: string, password: string, keepPassword: boolean) => invoke<"trusted_device" | "sms" | null>("sign_in", { appleId, password, keepPassword }),
  finishSignIn: (code: string) => invoke<void>("finish_sign_in", { code }),
  signOut: () => invoke<void>("sign_out"),
  teams: () => invoke<Team[]>("teams"),
  chooseTeam: (teamId: string) => invoke<void>("choose_team", { teamId }),
  setAnisette: (source: Anisette) => invoke<void>("set_anisette", { source }),
  install: (udid: string | null, handOff: boolean, ipa: string | null = null, testBuild: BuildRef | null = null, closePoki = false) => invoke<InstallResult>("install", { udid, ipa, handOff, testBuild, closePoki }),
  pokiRunning: (udid: string) => invoke<boolean | null>("poki_running", { udid }),
  devState: () => invoke<DevState>("dev_state"),
  devSetPrefs: (prefs: DevPrefs) => invoke<DevState>("dev_set_prefs", { prefs }),
  githubSignInStart: () => invoke<GithubSignIn>("github_sign_in_start"),
  githubSignInFinish: (pending: GithubSignIn) => invoke<DevState>("github_sign_in_finish", { pending }),
  githubSignInCancel: () => invoke<DevState>("github_sign_in_cancel"),
  githubUseCli: () => invoke<DevState>("github_use_cli"),
  githubUseToken: (token: string) => invoke<DevState>("github_use_token", { token }),
  githubSignOut: () => invoke<DevState>("github_sign_out"),
  testBuilds: (fresh = false) => invoke<TestBuildListing>("test_builds", { fresh }),
  testBuildDownload: (artifactId: number) => invoke<string>("test_build_download", { artifactId }),
  testBuildNext: () => invoke<TestBuild | null>("test_build_next"),
  testBuildSynced: (runId: number) => invoke<DevState>("test_build_synced", { runId }),
  testBuildsDeleteDownloads: () => invoke<DevState>("test_builds_delete_downloads"),
  records: () => invoke<Record_[]>("records"),
  renew: (udid: string) => invoke<Record_>("renew", { udid }),
  forgetPhone: (udid: string) => invoke<void>("forget_phone", { udid }),
  latestRelease: () => invoke<Release>("latest_release"),
  relayState: () => invoke<Deployed | null>("relay_state"),
  relayWorker: () => invoke<WorkerStatus>("relay_worker"),
  relayTokenSaved: () => invoke<boolean>("relay_token_saved"),
  relayForgetToken: () => invoke<void>("relay_forget_token"),
  relayAccounts: (token: string) => invoke<CfAccount[]>("relay_accounts", { token }),
  relayDeploy: (token: string, accountId: string) => invoke<Deployed>("relay_deploy", { token, accountId }),
  relayCheck: (address: string) => invoke<boolean>("relay_check", { address }),
  connectors: () => invoke<Connector[]>("connectors"),
  connectorAdd: (name: string, url: string) => invoke<Connector>("connector_add", { name, url }),
  connectorForget: (url: string) => invoke<void>("connector_forget", { url }),
  connectorCheck: (url: string) => invoke<Check>("connector_check", { url }),
  connectorSnippets: (url: string) => invoke<[string, string][]>("connector_snippets", { url }),
  logsStart: (udid: string, filter: string | null) => invoke<void>("logs_start", { udid, filter }),
  logsStop: () => invoke<void>("logs_stop"),
  mountDdi: (udid: string) => invoke<void>("mount_ddi", { udid }),
  supportBundle: (udid: string | null, outDir: string) => invoke<string>("support_bundle", { udid, outDir }),
  agentPrompt: () => invoke<string>("agent_prompt"),
  approveCertificateReplacement: () => invoke<number>("approve_certificate_replacement"),
  checkUpdate: () => invoke<UpdateInfo>("check_update"),
  installUpdate: () => invoke<{ path: string; relaunching: boolean }>("install_update"),
  channels: () => invoke<ChannelInfo[]>("channels"),
  setChannel: (channel: ChannelId) => invoke<ChannelInfo[]>("set_channel", { channel }),
  qrSvg: (text: string) => invoke<string>("qr_svg", { text }),
};

export function onProgress(job: string, f: (p: Progress) => void): Promise<UnlistenFn> {
  return listen<Progress>("progress", (e) => { if (e.payload.job === job) f(e.payload); });
}

export function failureText(e: unknown): string {
  if (e && typeof e === "object" && "message" in e) return String((e as Failure).message);
  return String(e);
}
export function failureKind(e: unknown): string {
  return e && typeof e === "object" && "kind" in e ? String((e as Failure).kind) : "message";
}

/** Asks whether to close Poki on the device (a native dialog). */
export async function askToClosePoki(name: string): Promise<boolean> {
  const { t } = await import("./i18n");
  const { ask } = await import("@tauri-apps/plugin-dialog");
  return ask(t("Poki is open on the device, in front or in the background. Poki Setup closes it so the update installs cleanly. You can skip this question under Developer, Test Builds."), { title: `${t("Close Poki on")} ${name}?`, kind: "warning", okLabel: t("Close Poki and Update"), cancelLabel: t("Cancel") });
}

/** Before an update replaces Poki: asks to close it when it is running (unless Developer says not to ask). */
export async function okToReplacePoki(udid: string, name: string): Promise<boolean> {
  const dev = await api.devState().catch(() => null);
  if (dev?.prefs.close_without_asking) return true;
  const records = await api.records().catch(() => [] as Record_[]);
  if (!records.some((r) => r.udid === udid)) return true;
  const running = await api.pokiRunning(udid).catch(() => null);
  return running === true ? askToClosePoki(name) : true;
}

/** An install that may replace a running Poki: asks first, and again if Poki was opened meanwhile. */
export async function installClosingPoki(udid: string, name: string, handOff: boolean, ipa: string | null = null, testBuild: BuildRef | null = null): Promise<InstallResult> {
  const dev = await api.devState().catch(() => null);
  if (!(await okToReplacePoki(udid, name))) throw { kind: "cancelled", message: "Nothing was installed. Poki is still open on the device." } as Failure;
  try {
    return await api.install(udid, handOff, ipa, testBuild, true);
  } catch (e) {
    if (failureKind(e) !== "poki_running" || dev?.prefs.close_without_asking) throw e;
    if (!(await askToClosePoki(name))) throw e;
    return await api.install(udid, handOff, ipa, testBuild, true);
  }
}
