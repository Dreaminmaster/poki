// Developer: the GitHub sign-in, and test builds from GitHub Actions artifacts (core devbuilds).
import { useEffect, useMemo, useState } from "react";
import { api, buildRef, failureText, installClosingPoki, onProgress, type DevPrefs, type DevState, type GithubSignIn, type PhoneRow, type Record_, type TestBuild, type TestBuildListing } from "../api";
import { t } from "../i18n";
import { Capsule, Card, ErrorBox, INSTALL_WEIGHTS, JobBar, Pill, Toggle, useInterval, useSteps } from "../ui";

const INSTALL_STEPS = [
  { id: "phone", title: "Phone" }, { id: "pair", title: "Pairing" }, { id: "devmode", title: "Developer Mode" },
  { id: "account", title: "Account" }, { id: "release", title: "Release" }, { id: "sign", title: "Signing" },
  { id: "install", title: "Install" }, { id: "pairing_file", title: "Pairing file" },
];

async function openUrl(url: string) {
  try {
    const { openUrl: open } = await import("@tauri-apps/plugin-opener");
    await open(url);
  } catch {
    window.open(url, "_blank");
  }
}

export function GitHubAccount({ dev, setDev, goBuilds }: { dev: DevState | null; setDev: (d: DevState) => void; goBuilds: () => void }) {
  const [code, setCode] = useState<GithubSignIn | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [token, setToken] = useState("");

  const signIn = async () => {
    setError(null);
    try {
      const c = await api.githubSignInStart();
      setCode(c);
      setDev(await api.githubSignInFinish(c));
    } catch (e) {
      setError(failureText(e));
    }
    setCode(null);
  };
  const run = async (f: () => Promise<DevState>) => {
    setError(null);
    try { setDev(await f()); } catch (e) { setError(failureText(e)); }
  };

  return (
    <>
      <h1 className="page-title">{t("GitHub Account")}</h1>
      <p className="page-sub">{t("Optional, for people developing Poki. Signed in, Poki Setup lists the test builds GitHub Actions makes and installs them.")}</p>
      <ErrorBox error={error} />
      {dev?.signed_in ? (
        <Card>
          <div className="row between">
            <div className="grow">
              <h2 style={{ margin: 0 }}>{dev.login ?? "GitHub"}</h2>
              <div className="muted small">{t(dev.source === "cli" ? "GitHub CLI on this computer" : dev.source === "token" ? "Token" : "GitHub sign-in")} {dev.repo}</div>
            </div>
            <Capsule onClick={goBuilds}>{t("Open Test Builds")}</Capsule>
            <Capsule kind="danger" sm onClick={() => run(api.githubSignOut)}>{t("Sign out")}</Capsule>
          </div>
        </Card>
      ) : (
        <>
          <Card>
            {code ? (
              <div className="row between">
                <div className="grow">
                  <div className="muted small">{t("Enter the code on GitHub")}</div>
                  <h2 className="mono" style={{ margin: "4px 0 0", fontSize: 22, userSelect: "text" }}>{code.user_code}</h2>
                </div>
                <Capsule onClick={() => { navigator.clipboard?.writeText(code.user_code); openUrl(code.verification_uri); }}>{t("Copy Code and Open GitHub")}</Capsule>
                <Capsule kind="ghost" onClick={() => { api.githubSignInCancel(); setCode(null); }}>{t("Cancel")}</Capsule>
              </div>
            ) : (
              <div className="row between">
                <span className="grow muted small">{t("The GitHub sign-in runs through Poki Preview Sign-in, a GitHub app that can only read the builds and pull requests of the Poki repository.")}</span>
                <Capsule onClick={signIn} disabled={!dev?.can_sign_in}>{t("Sign In with GitHub")}</Capsule>
                {dev?.cli_available && <Capsule kind="ghost" onClick={() => run(api.githubUseCli)}>{t("Use GitHub CLI")}</Capsule>}
              </div>
            )}
          </Card>
          <Card>
            <div className="row between">
              <input className="grow" type="password" placeholder="github_pat_" value={token} onChange={(e) => setToken(e.target.value)} />
              <Capsule kind="ghost" disabled={!token.trim()} onClick={() => run(async () => { const d = await api.githubUseToken(token); setToken(""); return d; })}>{t("Use Token")}</Capsule>
            </div>
            <div className="muted small" style={{ marginTop: 6 }}>{t("A fine-grained token with read access to Actions on the Poki repository is enough.")}</div>
          </Card>
        </>
      )}
    </>
  );
}

function ago(iso: string): string {
  const s = (Date.now() - Date.parse(iso)) / 1000;
  if (!isFinite(s)) return "";
  if (s < 90) return t("just now");
  if (s < 3600) return `${Math.round(s / 60)} ${t("min ago")}`;
  if (s < 86400) return `${Math.round(s / 3600)} ${t("h ago")}`;
  return `${Math.round(s / 86400)} ${t("d ago")}`;
}

export function TestBuilds({ dev, setDev }: { dev: DevState | null; setDev: (d: DevState) => void }) {
  const [list, setList] = useState<TestBuildListing | null>(null);
  const [rows, setRows] = useState<PhoneRow[]>([]);
  const [records, setRecords] = useState<Record_[]>([]);
  const [chosen, setChosen] = useState<string | null>(null);
  const [search, setSearch] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [running, setRunning] = useState<"install" | "download" | null>(null);
  const install = useSteps(INSTALL_STEPS);
  const download = useSteps([]);

  const load = (fresh = false) => api.testBuilds(fresh).then((l) => { setList(l); setError(null); }).catch((e) => setError(failureText(e)));
  useEffect(() => {
    const a = onProgress("install", install.apply);
    const b = onProgress("download", download.apply);
    return () => { a.then((f) => f()); b.then((f) => f()); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);
  useInterval(() => { load(true); }, 60000, []);
  useInterval(() => {
    if (running) return;
    api.phones().then(setRows).catch(() => setRows([]));
    api.records().then(setRecords).catch(() => {});
  }, 3000, [running]);

  const phone = rows.find((r) => r.phone.udid === chosen) ?? rows.find((r) => r.phone.link.kind === "usb") ?? rows[0] ?? null;
  const record = phone ? records.find((r) => r.udid === phone.phone.udid) : undefined;
  const prefs = dev?.prefs;
  const setPrefs = async (p: DevPrefs) => {
    try { setDev(await api.devSetPrefs(p)); load(); } catch (e) { setError(failureText(e)); }
  };

  const shown = useMemo(() => {
    const q = search.trim().toLowerCase();
    const all = list?.builds ?? [];
    if (!q) return all;
    return all.filter((b) => [b.title, b.branch, b.sha, b.workflow, b.actor ?? "", String(b.run_number), b.pr ? `${b.pr.number} ${b.pr.title}` : ""].join(" ").toLowerCase().includes(q));
  }, [list, search]);

  const doInstall = async (b: TestBuild | null, ipa: string | null = null) => {
    if (!phone) { setError(t("Connect the device to install on.")); return; }
    setRunning("install"); setError(null); install.reset();
    try {
      await installClosingPoki(phone.phone.udid, phone.facts?.name ?? t("Device"), false, ipa, b ? buildRef(b) : null);
      api.records().then(setRecords);
      load();
    } catch (e) { const m = failureText(e); install.fail(m); setError(m); }
    setRunning(null);
  };
  const doDownload = async (b: TestBuild) => {
    if (b.artifact_id == null) return;
    setRunning("download"); setError(null); download.reset();
    try { await api.testBuildDownload(b.artifact_id); load(); setDev(await api.devState()); } catch (e) { const m = failureText(e); download.fail(m); setError(m); }
    setRunning(null);
  };
  const pickIpa = async () => {
    const { open } = await import("@tauri-apps/plugin-dialog");
    const f = (await open({ multiple: false, filters: [{ name: "IPA", extensions: ["ipa"] }] })) as string | null;
    if (f) doInstall(null, f);
  };

  if (!dev?.signed_in) return <Card><span className="muted">{t("Sign in to GitHub to see test builds.")}</span></Card>;

  return (
    <>
      <div className="row between">
        <h1 className="page-title grow">{t("Test Builds")}</h1>
        <Capsule kind="ghost" sm onClick={pickIpa} disabled={!phone || running !== null}>{t("Install IPA File…")}</Capsule>
        <Capsule kind="ghost" sm onClick={() => load(true)}>{t("Refresh")}</Capsule>
      </div>
      <p className="page-sub">{t("Builds of Poki from GitHub Actions, newest first. Install one on a device the way Set up installs a release.")}</p>
      <ErrorBox error={error} />

      <Card>
        {rows.length === 0 ? <span className="muted">{t("Connect an iPhone or iPad with a cable to install a build.")}</span> : (
          <div className="row between">
            {rows.length > 1 ? (
              <div className="seg">
                {rows.map((r) => <button key={r.phone.udid} className={phone?.phone.udid === r.phone.udid ? "on" : ""} onClick={() => setChosen(r.phone.udid)}>{r.facts?.name ?? r.phone.udid.slice(0, 8)}</button>)}
              </div>
            ) : <b className="grow">{phone?.facts?.name ?? t("Device")}</b>}
            <span className="muted small">{record?.test_build ? `${t("Test build")} ${record.test_build.run_number} ${t("from")} ${record.test_build.branch}` : record ? `Poki ${record.version} (${record.build})` : t("No Poki from this computer")}</span>
          </div>
        )}
        {running === "install" || install.steps.some((s) => s.state === "failed") ? <><div className="hair" /><JobBar steps={install.steps} running={running === "install"} weights={INSTALL_WEIGHTS} doneTitle="Poki is installed" /></> : null}
        {running === "download" && <><div className="hair" /><JobBar steps={download.steps} running doneTitle="Downloaded" /></>}
      </Card>

      {prefs && (
        <Card>
          <div className="row" style={{ flexWrap: "wrap", gap: 12 }}>
            <Toggle on={prefs.only_mine} onChange={(v) => setPrefs({ ...prefs, only_mine: v })} label={t("Only builds I started")} />
            <Toggle on={prefs.with_pr_only} onChange={(v) => setPrefs({ ...prefs, with_pr_only: v })} label={t("Only builds with a pull request")} />
            <select value={prefs.branch ?? ""} onChange={(e) => setPrefs({ ...prefs, branch: e.target.value || null })}>
              <option value="">{t("All branches")}</option>
              {(list?.branches ?? []).map((b) => <option key={b} value={b}>{b}</option>)}
            </select>
            <input className="grow" placeholder={t("Search")} value={search} onChange={(e) => setSearch(e.target.value)} />
          </div>
        </Card>
      )}

      <Card>
        <div className="row between"><b>{t("Builds")}</b><span className="muted small">{list ? `${shown.length} / ${list.total}` : t("Asking GitHub for builds")}</span></div>
        {list && shown.length === 0 && <div className="muted" style={{ marginTop: 8 }}>{t(list.total ? "No build matches the filters." : "GitHub has no test builds right now.")}</div>}
        {shown.map((b) => {
          const onDevice = record?.test_build?.artifact_id === b.artifact_id && b.artifact_id != null;
          return (
            <div className="build" key={b.run_id}>
              <div className="num">{b.run_number}</div>
              <div className="grow">
                <div className="row" style={{ gap: 6 }}>
                  <b>{b.title || b.branch}</b>
                  {onDevice && <Pill tone="ok">{t("On device")}</Pill>}
                  {b.state === "building" && <Pill tone="warn">{t("Building")}</Pill>}
                  {b.state === "expired" && <Pill>{t("Expired")}</Pill>}
                  {b.downloaded && !onDevice && <Pill>{t("Downloaded")}</Pill>}
                </div>
                <div className="facts">
                  <span>{b.branch}</span><span className="mono">{b.sha.slice(0, 7)}</span>{b.actor && <span>{b.actor}</span>}<span>{ago(b.created_at)}</span>
                  {b.size > 0 && <span>{(b.size / 1e6).toFixed(0)} MB</span>}{b.workflow !== "iOS IPA" && <span>{b.workflow}</span>}
                </div>
                {b.pr && <a className="small" href="#" onClick={(e) => { e.preventDefault(); openUrl(b.pr!.url); }}>#{b.pr.number} {b.pr.title}</a>}
              </div>
              <a className="small" href="#" onClick={(e) => { e.preventDefault(); openUrl(b.run_url); }}>{t("View run")}</a>
              {b.state === "ready" && !b.downloaded && <Capsule kind="ghost" sm disabled={running !== null} onClick={() => doDownload(b)}>{t("Download")}</Capsule>}
              {b.state === "ready" && <Capsule sm disabled={running !== null || !phone} onClick={() => doInstall(b)}>{t(onDevice ? "Reinstall" : "Install")}</Capsule>}
            </div>
          );
        })}
      </Card>

      {prefs && (
        <Card>
          <b>{t("Automatic")}</b>
          <div className="row" style={{ flexWrap: "wrap", gap: 12, marginTop: 8 }}>
            <Toggle on={prefs.auto_download} onChange={(v) => setPrefs({ ...prefs, auto_download: v })} label={t("Download new builds")} />
            <Toggle on={prefs.auto_install} onChange={(v) => setPrefs({ ...prefs, auto_install: v, auto_install_udid: prefs.auto_install_udid ?? phone?.phone.udid ?? null })} label={t("Install new builds")} />
            {prefs.auto_install && (
              <select value={prefs.auto_install_udid ?? ""} onChange={(e) => setPrefs({ ...prefs, auto_install_udid: e.target.value || null })}>
                <option value="">{t("Choose a device")}</option>
                {[...rows.map((r) => ({ id: r.phone.udid, name: r.facts?.name ?? r.phone.udid })), ...records.filter((r) => !rows.some((x) => x.phone.udid === r.udid)).map((r) => ({ id: r.udid, name: r.phone_name }))].map((d) => <option key={d.id} value={d.id}>{d.name}</option>)}
              </select>
            )}
            <Toggle on={prefs.close_without_asking} onChange={(v) => setPrefs({ ...prefs, close_without_asking: v })} label={t("Close Poki without asking")} />
            <Toggle on={prefs.keep_on_renew} onChange={(v) => setPrefs({ ...prefs, keep_on_renew: v })} label={t("Renewals keep the test build")} />
          </div>
          <div className="muted small" style={{ marginTop: 8 }}>{t("Poki Setup checks GitHub every two minutes and takes new builds that match the filters.")}</div>
          <div className="row between" style={{ marginTop: 10 }}>
            <span className="muted small grow">{t("Downloaded builds")} {(dev.downloads_bytes / 1e6).toFixed(0)} MB</span>
            <Capsule kind="danger" sm disabled={!dev.downloads_bytes} onClick={async () => setDev(await api.testBuildsDeleteDownloads())}>{t("Delete downloads")}</Capsule>
          </div>
        </Card>
      )}
    </>
  );
}

/** The automatic sync, for the whole app: every two minutes while sync is on. */
export function useTestBuildSync(dev: DevState | null, setDev: (d: DevState) => void, notify: (text: string) => void) {
  useInterval(() => {
    if (!dev?.signed_in || !(dev.prefs.auto_download || dev.prefs.auto_install)) return;
    (async () => {
      const next = await api.testBuildNext().catch(() => null);
      if (!next || next.artifact_id == null) return;
      const p = dev.prefs;
      const rows = await api.phones().catch(() => [] as PhoneRow[]);
      const target = p.auto_install_udid ? rows.find((r) => r.phone.udid === p.auto_install_udid && r.facts) : undefined;
      const account = await api.account().catch(() => null);
      if (p.auto_install && target && account?.signed_in) {
        try {
          await installClosingPoki(target.phone.udid, target.facts?.name ?? t("Device"), false, null, buildRef(next));
          notify(`${t("Installed test build")} ${next.run_number}`);
        } catch (e) { notify(`${t("Test build")} ${next.run_number} ${failureText(e)}`); }
        setDev(await api.testBuildSynced(next.run_id));
        return;
      }
      if (p.auto_download && !next.downloaded) {
        try { await api.testBuildDownload(next.artifact_id); } catch (e) { notify(failureText(e)); setDev(await api.testBuildSynced(next.run_id)); return; }
      }
      if (!p.auto_install) setDev(await api.testBuildSynced(next.run_id));
    })();
  }, 120000, [dev?.signed_in, dev?.prefs.auto_download, dev?.prefs.auto_install, dev?.prefs.auto_install_udid]);
}
