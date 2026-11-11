import { useEffect, useRef, useState } from "react";
import { api, failureText, type GithubSignIn, type PreviewState } from "../api";
import { t } from "../i18n";
import { Capsule, Card, ErrorBox, Toggle } from "../ui";

/// The GitHub Account, under the Apple Account: GitHub's device sign-in and the Preview Builds
/// switch, which is there only while signed in. Signed in, the Pre-alpha channel is offered, and
/// with the switch on Settings lists preview builds of pull requests under the channel.
export function GitHubCard() {
  const [state, setState] = useState<PreviewState | null>(null);
  const [pending, setPending] = useState<GithubSignIn | null>(null);
  const [error, setError] = useState<string | null>(null);
  // The sign-in now waited for: one that was stopped meanwhile is not taken.
  const waiting = useRef<string | null>(null);
  useEffect(() => { api.previews().then(setState).catch((e) => setError(failureText(e))); }, []);
  const fail = (e: unknown) => setError(failureText(e));
  const signIn = async () => {
    setError(null);
    try {
      const code = await api.githubSignInStart();
      waiting.current = code.device_code;
      setPending(code);
      const s = await api.githubSignInFinish(code);
      if (waiting.current === code.device_code) setState(s);
      else setState(await api.githubSignOut());
    } catch (e) {
      if (waiting.current) fail(e);
    }
    waiting.current = null;
    setPending(null);
  };
  const open = async (code: GithubSignIn) => {
    const { writeText } = await import("@tauri-apps/plugin-clipboard-manager");
    const { openUrl } = await import("@tauri-apps/plugin-opener");
    await writeText(code.user_code).catch(() => {});
    openUrl(code.verification_uri);
  };
  return (
    <Card>
      <h2>{t("GitHub Account")}</h2>
      <p className="muted small">{state?.has_token ? t("The Pre-alpha channel is now offered. With Preview Builds on, Settings lists builds of pull requests under the channel.") : t("Optional, for people developing Poki. Poki Setup asks GitHub for no permissions.")}</p>
      <ErrorBox error={error} />
      {state?.has_token ? (
        <div className="stack">
          <div className="row" style={{ alignItems: "center" }}>
            <span className="grow">{state.github_login ?? t("Signed in")}</span>
            <Capsule kind="ghost" onClick={() => api.githubSignOut().then(setState).catch(fail)}>{t("Sign out")}</Capsule>
          </div>
          <Toggle on={state.enabled} onChange={(on) => api.setPreviewSwitch(on).then(setState).catch(fail)} label={t("Preview Builds")} />
        </div>
      ) : pending ? (
        <div className="stack">
          <div className="mono" style={{ fontSize: 22, letterSpacing: "0.15em", userSelect: "text" }}>{pending.user_code}</div>
          <div className="row" style={{ alignItems: "center" }}>
            <Capsule onClick={() => open(pending)}>{t("Copy Code and Open GitHub")}</Capsule>
            <Capsule kind="ghost" onClick={() => { waiting.current = null; setPending(null); }}>{t("Stop")}</Capsule>
            <span className="muted small">{t("Waiting for GitHub")}</span>
          </div>
        </div>
      ) : (
        <Capsule disabled={!state?.can_sign_in} onClick={signIn}>{t("Sign In with GitHub")}</Capsule>
      )}
    </Card>
  );
}

/// Under the channel: a pull request's preview build to install instead of the channel's release.
/// Shown only with Preview Builds on (GitHub Account).
export function PreviewPicker({ onChange, onError }: { onChange: () => void; onError: (e: string) => void }) {
  const [state, setState] = useState<PreviewState | null>(null);
  useEffect(() => { api.previews().then(setState).catch(() => {}); }, []);
  if (!state?.enabled) return null;
  const pick = (pr: number | null) => api.setPreview(pr).then((s) => { setState(s); onChange(); }).catch((e) => onError(failureText(e)));
  return (
    <div className="stack" style={{ marginTop: 14 }}>
      <h2>{t("Preview Build")}</h2>
      <p className="muted small">{state.builds.length ? t("Not on any channel, for testing a pull request. Poki Setup installs and renews Poki from the chosen build until you choose None.") : t("No pull request has a preview build")}</p>
      <label className="row" style={{ padding: "4px 0" }}>
        <input type="radio" name="preview" checked={state.selected == null} onChange={() => pick(null)} />
        <span className="grow">{t("None")}</span>
      </label>
      {state.builds.map((r) => r.preview && (
        <label key={r.preview.pr} className="row" style={{ padding: "4px 0" }}>
          <input type="radio" name="preview" checked={state.selected === r.preview.pr} onChange={() => pick(r.preview!.pr)} />
          <span className="grow">PR {r.preview.pr} <span className="mono">{r.version} ({r.build})</span> <span className="muted small">{r.preview.title}</span></span>
        </label>
      ))}
    </div>
  );
}
