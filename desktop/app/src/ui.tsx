import type { ReactNode } from "react";
import { useEffect, useState } from "react";
import type { Progress } from "./api";
import { t } from "./i18n";

export function Card({ children, white, className = "" }: { children: ReactNode; white?: boolean; className?: string }) {
  return <section className={`card fade ${white ? "white" : ""} ${className}`}>{children}</section>;
}

export function Capsule({ children, onClick, disabled, kind = "", big, sm, type = "button" }: { children: ReactNode; onClick?: () => void; disabled?: boolean; kind?: "" | "ghost" | "danger"; big?: boolean; sm?: boolean; type?: "button" | "submit" }) {
  return <button type={type} className={`capsule ${kind} ${big ? "big" : ""} ${sm ? "sm" : ""}`} onClick={onClick} disabled={disabled}>{children}</button>;
}

export function Toggle({ on, onChange, label }: { on: boolean; onChange: (v: boolean) => void; label: string }) {
  return (
    <button type="button" className={`toggle ${on ? "on" : ""}`} onClick={() => onChange(!on)} aria-pressed={on}>
      <span className="track" /><span>{label}</span>
    </button>
  );
}

export function Field({ label, children }: { label: string; children: ReactNode }) {
  return <div className="field"><label>{label}</label>{children}</div>;
}

export function Pill({ children, tone = "" }: { children: ReactNode; tone?: "" | "ok" | "bad" | "warn" }) {
  return <span className={`pill ${tone}`}>{children}</span>;
}

export function ErrorBox({ error }: { error: string | null }) {
  return error ? <div className="error">{t(error)}</div> : null;
}

export function Qr({ svg }: { svg: string }) {
  return <div className="qr" dangerouslySetInnerHTML={{ __html: svg }} />;
}

/** The ordered steps of a job, drawn from its progress events. */
export type Step = { id: string; title: string; state: "todo" | "active" | "done" | "failed" | "waiting"; detail?: string; fraction?: number; notes: string[] };

export function useSteps(initial: { id: string; title: string }[]) {
  const [steps, setSteps] = useState<Step[]>(initial.map((s) => ({ ...s, state: "todo", notes: [] })));
  const apply = (p: Progress) => {
    setSteps((prev) => {
      const next = prev.map((s) => ({ ...s, notes: [...s.notes] }));
      const find = (id: string) => next.find((s) => s.id === id);
      if (p.kind === "step") {
        let s = find(p.id);
        if (!s) { s = { id: p.id, title: p.title, state: "todo", notes: [] }; next.push(s); }
        s.title = p.title; s.state = "active"; s.detail = undefined; s.fraction = undefined;
      } else if (p.kind === "part") {
        const s = find(p.id); if (s) { s.fraction = p.fraction; if (p.detail) s.detail = p.detail; s.state = "active"; }
      } else if (p.kind === "note") {
        const s = find(p.id) ?? next[next.length - 1]; if (s) s.notes.push(p.text);
      } else if (p.kind === "waiting") {
        const s = find(p.id); if (s) { s.state = "waiting"; s.detail = p.text; }
      } else if (p.kind === "done") {
        if (p.id === "all") return next;
        const s = find(p.id); if (s) { s.state = "done"; s.detail = p.detail ?? undefined; s.fraction = undefined; }
      }
      return next;
    });
  };
  const fail = (text: string) => setSteps((prev) => prev.map((s) => (s.state === "active" || s.state === "waiting" ? { ...s, state: "failed", detail: text } : s)));
  const reset = () => setSteps(initial.map((s) => ({ ...s, state: "todo", notes: [] })));
  return { steps, apply, fail, reset };
}

export function Steps({ steps }: { steps: Step[] }) {
  return (
    <ol className="steps">
      {steps.map((s, i) => (
        <li key={s.id} className={s.state}>
          <span className="dot">{s.state === "done" ? "✓" : s.state === "failed" ? "!" : i + 1}</span>
          <div className="grow">
            <div>{t(s.title)}</div>
            {s.detail && <div className="detail">{s.detail}</div>}
            {s.notes.map((n, j) => <div className="detail" key={j}>· {n}</div>)}
            {s.fraction !== undefined && s.state === "active" && <div className="bar"><i style={{ width: `${Math.round(s.fraction * 100)}%` }} /></div>}
          </div>
        </li>
      ))}
    </ol>
  );
}

/** How much of the bar each install step takes, by how long it usually runs. */
export const INSTALL_WEIGHTS: Record<string, number> = { phone: 2, pair: 3, devmode: 2, account: 3, release: 16, sign: 18, profiles: 3, install: 40, pairing_file: 4, seed: 9, mount: 8 };
export const RENEW_WEIGHTS: Record<string, number> = { release: 16, sign: 18, profiles: 3, install: 40 };

/** A job as one bar: the step under way and its detail under the bar, the steps behind Details. */
export function JobBar({ steps, running, weights, doneTitle = "Done" }: { steps: Step[]; running: boolean; weights?: Record<string, number>; doneTitle?: string }) {
  const [open, setOpen] = useState(false);
  const failed = [...steps].reverse().find((s) => s.state === "failed");
  const current = failed ?? [...steps].reverse().find((s) => s.state === "active" || s.state === "waiting") ?? [...steps].reverse().find((s) => s.state === "done");
  const finished = !running && !failed && steps.some((s) => s.state !== "todo");
  const part = (s: Step) => (s.state === "done" ? 1 : s.state === "todo" ? 0 : Math.min(Math.max(s.fraction ?? 0, 0), 1));
  let fraction = 0;
  if (finished) fraction = 1;
  else if (weights) {
    const total = Object.values(weights).reduce((a, b) => a + b, 0);
    fraction = total ? Math.min(steps.reduce((a, s) => a + (weights[s.id] ?? 0) * part(s), 0) / total, 0.99) : 0;
  } else if (steps.length) fraction = Math.min(steps.reduce((a, s) => a + part(s), 0) / steps.length, 0.99);
  const line = current?.detail || current?.notes[current.notes.length - 1];
  return (
    <div className={`jobbar ${failed ? "failed" : ""} ${current?.state === "waiting" ? "waiting" : ""}`}>
      <div className="row between">
        <b className="grow">{finished ? t(doneTitle) : t(current?.title ?? "Starting")}</b>
        <span className="muted small mono">{Math.round(fraction * 100)}%</span>
      </div>
      <div className="bar wide"><i style={{ width: `${Math.round(fraction * 100)}%` }} /></div>
      {line && <div className="detail">{line}</div>}
      <button type="button" className="linkish small" onClick={() => setOpen(!open)}>{t(open ? "Hide Details" : "Show Details")}</button>
      {open && <Steps steps={steps.filter((s) => s.state !== "todo")} />}
    </div>
  );
}

export function useInterval(f: () => void, ms: number, deps: unknown[] = []) {
  useEffect(() => {
    f();
    const h = setInterval(f, ms);
    return () => clearInterval(h);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, deps);
}

/** "0.2.2-320" as people read it, "0.2.2 (320)"; update checks keep the plain form. */
export function displayVersion(v?: string | null): string {
  if (!v) return "";
  const m = /^(.*)-(\d+)$/.exec(v);
  return m ? `${m[1]} (${m[2]})` : v;
}

export function Copy({ text }: { text: string }) {
  const [done, setDone] = useState(false);
  return (
    <Capsule kind="ghost" sm onClick={async () => {
      const { writeText } = await import("@tauri-apps/plugin-clipboard-manager");
      await writeText(text);
      setDone(true); setTimeout(() => setDone(false), 1200);
    }}>{done ? t("Copied") : t("Copy")}</Capsule>
  );
}
