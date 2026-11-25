#!/usr/bin/env python3
"""Beta and Stable promotions for Poki's iPhone app (docs/release-channels.md).

A promotion moves one already-built IPA up a channel without rebuilding it:
  alpha  app-0.3.0-alpha.712  ->  beta    app-0.3.0-beta.1  (prerelease)
  beta   app-0.3.0-beta.1     ->  stable  app-0.3.0         (full release, never marked Latest)
Each one is a record in .github/channels.json, added by a promotion PR (propose), checked on that
PR (gate) and published when it merges into main (publish-promotion.yml).

  promotion.py propose <beta|stable> [from-tag] [override reason]   edits channels.json (+ VERSION)
  promotion.py pending                                              the record not yet published, as JSON
  promotion.py changelog [--file PATH] [--version V --channel C] [--extract]
                                                                    exit 1 if CHANGELOG.md lacks this version
  promotion.py soak                                                 exit 1 if a stable's beta is too new
  promotion.py gym-run <head sha> [exclude run id]                  newest completed gate run with scorecards
  promotion.py gym <baseline dir> <new dir>                         exit 1 if the Gym got worse

Needs gh (GH_TOKEN, GH_REPO). Prints GitHub Actions outputs as key=value lines on stdout.
"""
import argparse
import datetime as dt
import json
import os
import re
import subprocess
import sys
from pathlib import Path

CHANNELS = Path(".github/channels.json")
VERSION_FILE = Path("native/ios-app/VERSION")
CHANGELOG = Path("CHANGELOG.md")


def gh(*args):
    return subprocess.run(["gh", *args], check=True, capture_output=True, text=True).stdout.strip()


def gh_json(*args):
    out = gh(*args)
    return json.loads(out) if out else None


def now():
    return dt.datetime.now(dt.timezone.utc)


def load():
    return json.loads(CHANNELS.read_text())


def save(data):
    CHANNELS.write_text(json.dumps(data, indent=2) + "\n")


def tag_sha(tag):
    return gh("api", f"repos/{os.environ['GH_REPO']}/commits/{tag}", "--jq", ".sha")


def tag_exists(tag):
    r = subprocess.run(["gh", "api", f"repos/{os.environ['GH_REPO']}/git/ref/tags/{tag}"], capture_output=True)
    return r.returncode == 0


def releases():
    return gh_json("api", "--paginate", f"repos/{os.environ['GH_REPO']}/releases?per_page=100", "--jq", "[.[] | {tag_name, draft, prerelease, published_at, assets: [.assets[].name]}]") or []


def bump_patch(v):
    a, b, c = (int(x) for x in v.split("."))
    return f"{a}.{b}.{c + 1}"


def vkey(v):
    return tuple(int(x) for x in v.split("."))


def propose(channel, src=None, override=None):
    data = load()
    rec = {"channel": channel, "proposed": now().strftime("%Y-%m-%dT%H:%M:%SZ")}
    if channel == "beta":
        if not src:
            ipa = next(n for n in gh("release", "view", "app-alpha-latest", "--json", "assets", "--jq", ".assets[].name").splitlines() if n.startswith("Poki-external-") and n.endswith(".ipa"))
            stem = ipa[len("Poki-external-"):-len(".ipa")]
            src = "app-{}-alpha.{}".format(*stem.rsplit("-", 1))
        m = re.fullmatch(r"app-(\d+\.\d+\.\d+)-alpha\.(\d+)", src)
        if not m:
            sys.exit(f"{src} is not app-X.Y.Z-alpha.N")
        version, build = m.groups()
        taken = [t for t in gh("api", "--paginate", f"repos/{os.environ['GH_REPO']}/tags?per_page=100", "--jq", ".[].name").splitlines() if t.startswith(f"app-{version}-beta.")]
        taken += [p["tag"] for p in data["promotions"] if p["tag"].startswith(f"app-{version}-beta.")]
        k = 1 + max([int(t.rsplit(".", 1)[1]) for t in taken], default=0)
        label = f"{version}-beta.{k}"
        if tag_exists(f"app-{version}"):
            sys.exit(f"Poki {version} is already Stable; a beta of it would never be offered. Promote a newer alpha.")
        rec.update(version=label, tag=f"app-{label}", base_version=version, build=build, source=src, sha=tag_sha(src))
        # Later alphas must sort above this beta, so main moves on to the next version.
        current = VERSION_FILE.read_text().strip()
        if vkey(current) <= vkey(version):
            VERSION_FILE.write_text(bump_patch(version) + "\n")
            rec["version_bump"] = f"{current} -> {bump_patch(version)}"
    elif channel == "stable":
        if not src:
            betas = [r for r in releases() if not r["draft"] and re.fullmatch(r"app-\d+\.\d+\.\d+-beta\.\d+", r["tag_name"])]
            if not betas:
                sys.exit("no published beta to promote")
            src = max(betas, key=lambda r: r["published_at"])["tag_name"]
        m = re.fullmatch(r"app-(\d+\.\d+\.\d+)-beta\.(\d+)", src)
        if not m:
            sys.exit(f"{src} is not app-X.Y.Z-beta.K")
        version = m.group(1)
        if tag_exists(f"app-{version}"):
            sys.exit(f"app-{version} already exists")
        beta = next((p for p in data["promotions"] if p["tag"] == src), {})
        rec.update(version=version, tag=f"app-{version}", base_version=version, build=beta.get("build", ""), source=src, sha=tag_sha(src))
        if override:
            rec["soak_override"] = override
    else:
        sys.exit("channel is beta or stable")
    data["promotions"].append(rec)
    save(data)
    for k in ("channel", "version", "tag", "source", "sha"):
        print(f"{k}={rec[k]}")
    print(f"branch=promote/{channel}-{rec['version']}")


RECORD_FORMS = {
    "beta": {"tag": r"app-\d+\.\d+\.\d+-beta\.\d+", "source": r"app-\d+\.\d+\.\d+-alpha\.\d+",
             "version": r"\d+\.\d+\.\d+-beta\.\d+", "build": r"\d+"},
    "stable": {"tag": r"app-\d+\.\d+\.\d+", "source": r"app-\d+\.\d+\.\d+-beta\.\d+",
               "version": r"\d+\.\d+\.\d+", "build": r"\d*"},
}


def check(rec):
    """A record from channels.json decides the release name and the approval environment, so a
    malformed one stops the publish instead of slipping past the stable approval."""
    forms = RECORD_FORMS.get(rec.get("channel"))
    if not forms:
        sys.exit(f"promotion record has channel {rec.get('channel')!r}; it must be beta or stable")
    fields = dict(forms, sha=r"[0-9a-f]{40}", base_version=r"\d+\.\d+\.\d+")
    for key, form in fields.items():
        if not re.fullmatch(form, str(rec.get(key, ""))):
            sys.exit(f"promotion record field {key}={rec.get(key)!r} is not in the expected form")
    if not rec["tag"].endswith(rec["version"]) or not rec["version"].startswith(rec["base_version"]):
        sys.exit("promotion record's tag, version and base_version disagree")
    return rec


def pending():
    data = load()
    for rec in reversed(data["promotions"]):
        if not tag_exists(rec["tag"]):
            print(json.dumps(check(rec)))
            return rec
    print("{}")
    return None


CHANGELOG_HEADING_RE = re.compile(
    r"^##\s+\[(?P<version>\d+\.\d+\.\d+(?:-beta\.\d+)?)\]"
    r"(?:\s+(?P<qual>Beta(?:\s+\d+)?))?"
    r"(?:\s*-\s*(?P<date>.*))?\s*$"
)
LINK_DEF_RE = re.compile(r"^\[[^\]]+\]:\s+\S+")


def _heading_priority(match, channel, version, base_version):
    h_version = match.group("version")
    h_qual = match.group("qual")
    if "-beta." in h_version and h_qual:
        return None
    if "-beta." in h_version:
        h_base, beta_part = h_version.split("-beta.", 1)
        h_kind, h_beta = "beta_exact", int(beta_part)
    elif h_qual:
        h_base = h_version
        if h_qual == "Beta":
            h_kind, h_beta = "beta_generic", None
        else:
            h_kind, h_beta = "beta_exact", int(h_qual.split()[1])
    else:
        h_base, h_kind, h_beta = h_version, "base", None

    if h_base != base_version:
        return None
    if channel == "beta":
        m = re.fullmatch(r"(\d+\.\d+\.\d+)-beta\.(\d+)", version)
        if not m or m.group(1) != base_version:
            sys.exit(f"beta version {version!r} does not match base_version {base_version!r}")
        target_beta = int(m.group(2))
        if h_kind == "beta_exact" and h_beta == target_beta:
            return 0
        if target_beta == 1 and h_kind == "beta_generic":
            return 1
        if target_beta == 1 and h_kind == "base":
            return 2
        return None
    if channel == "stable":
        if version != base_version:
            sys.exit(f"stable version {version!r} does not match base_version {base_version!r}")
        return 0 if h_kind == "base" else None
    sys.exit(f"promotion channel {channel!r} must be beta or stable")


def _clean_section_body(lines):
    body = list(lines)
    while body and (not body[-1].strip() or LINK_DEF_RE.match(body[-1].strip())):
        body.pop()
    while body and not body[0].strip():
        body.pop(0)
    return body


def _has_release_notes(body_lines):
    for line in body_lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if re.fullmatch(r"[-*+]\s*", stripped) or LINK_DEF_RE.match(stripped):
            continue
        return True
    return False


def find_changelog_section(text, channel, version, base_version, path_label="CHANGELOG.md"):
    lines = text.splitlines()
    sections = [i for i, line in enumerate(lines) if re.match(r"^##\s+", line)]
    best = None
    for idx, start in enumerate(sections):
        heading = lines[start].strip()
        match = CHANGELOG_HEADING_RE.match(heading)
        if not match:
            continue
        priority = _heading_priority(match, channel, version, base_version)
        if priority is None:
            continue
        end = sections[idx + 1] if idx + 1 < len(sections) else len(lines)
        if best is None or priority < best[0]:
            best = (priority, heading, match, lines[start + 1:end])
    if best is None:
        sys.exit(
            f"{path_label} has no dated section for Poki {version}. "
            f"Add '## [{version}] - YYYY-MM-DD' with user-visible changes before releasing."
        )
    _, heading, match, raw_body = best
    date_str = (match.group("date") or "").strip()
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", date_str):
        sys.exit(f"{path_label} section '{heading}' must include a YYYY-MM-DD release date.")
    try:
        dt.date.fromisoformat(date_str)
    except ValueError:
        sys.exit(f"{path_label} section '{heading}' has invalid release date {date_str!r}.")
    body = _clean_section_body(raw_body)
    if not _has_release_notes(body):
        sys.exit(f"{path_label} section '{heading}' has no release notes.")
    return heading, "\n".join(body)


def changelog(argv):
    parser = argparse.ArgumentParser(prog="promotion.py changelog")
    parser.add_argument("--file", default=str(CHANGELOG))
    parser.add_argument("--version")
    parser.add_argument("--base-version")
    parser.add_argument("--channel")
    parser.add_argument("--extract", action="store_true")
    args = parser.parse_args(argv)

    if args.version or args.channel or args.base_version:
        if not args.version or not args.channel:
            sys.exit("--version and --channel must be given together")
        channel = args.channel
        version = args.version
        base_version = args.base_version or re.sub(r"-beta\.\d+$", "", version)
    else:
        data = load()
        rec = next((r for r in reversed(data["promotions"]) if not tag_exists(r["tag"])), None)
        if not rec:
            print("no pending promotion")
            return
        rec = check(rec)
        channel, version, base_version = rec["channel"], rec["version"], rec["base_version"]

    path = Path(args.file)
    if not path.is_file():
        sys.exit(f"{args.file} not found; add a dated section for Poki {version} before releasing.")
    heading, body = find_changelog_section(
        path.read_text(encoding="utf-8"),
        channel,
        version,
        base_version,
        path_label=args.file,
    )
    if args.extract:
        print(body)
    else:
        print(f"{args.file} has a dated section for Poki {version}: {heading}")


def soak():
    data = load()
    rec = next((r for r in reversed(data["promotions"]) if not tag_exists(r["tag"])), None)
    if not rec or rec["channel"] != "stable":
        print("not a stable promotion")
        return
    if rec.get("soak_override"):
        print(f"soak skipped by hand: {rec['soak_override']}")
        return
    info = gh_json("release", "view", rec["source"], "--json", "publishedAt")
    published = dt.datetime.fromisoformat(info["publishedAt"].replace("Z", "+00:00"))
    days = data.get("soak_days", 3)
    ready = published + dt.timedelta(days=days)
    if now() < ready:
        eastern = ready.astimezone(dt.timezone(dt.timedelta(hours=-5)))
        sys.exit(f"{rec['source']} has been out for less than {days} days; it can become Stable after {eastern:%b %-d %-I:%M %p} ET. To skip the wait, add the soak-override label to this PR or propose again with a reason.")
    print(f"{rec['source']} has been out since {info['publishedAt']}, at least {days} days")
    blockers = gh("issue", "list", "--label", "blocker", "--state", "open", "--json", "number", "--jq", ".[].number").split()
    if blockers:
        sys.exit("Open blocker issues: " + ", ".join("#" + n for n in blockers) + ". Close them, or add the soak-override label to ship anyway.")


SCORECARD_ARTIFACTS = ("gym-scorecard", "gym-scorecard-inprocess")


def gym_run(head_sha, exclude_run_id=None):
    if not re.fullmatch(r"[0-9a-f]{40}", head_sha or ""):
        sys.exit(f"head sha {head_sha!r} is not a 40-character commit SHA")
    runs = gh_json(
        "run", "list",
        "--workflow", "promotion-gate.yml",
        "--commit", head_sha,
        "--limit", "50",
        "--json", "databaseId,status,conclusion",
    ) or []
    exclude = str(exclude_run_id) if exclude_run_id else None
    partial = None
    for run in runs:
        if run.get("status") != "completed":
            continue
        run_id = str(run.get("databaseId", ""))
        if not run_id or run_id == exclude:
            continue
        payload = gh_json("api", f"repos/{os.environ['GH_REPO']}/actions/runs/{run_id}/artifacts?per_page=100") or {}
        names = {a.get("name") for a in payload.get("artifacts", []) if not a.get("expired", False)}
        if all(name in names for name in SCORECARD_ARTIFACTS):
            print(run_id)
            return run_id
        if partial is None and any(name in names for name in SCORECARD_ARTIFACTS):
            partial = run_id
    if partial:
        print(partial)
    return partial


def failures(path):
    m = re.search(r"failures: (\d+)\s*$", Path(path).read_text(), re.M) if Path(path).exists() else None
    return int(m.group(1)) if m else None


def gym(base_dir, new_dir):
    worse = []
    for name in ("gym-scorecard.txt", "gym-scorecard-inprocess.txt"):
        new = failures(Path(new_dir) / name)
        base = failures(Path(base_dir) / name)
        print(f"{name}: {new} failures (last beta: {'none' if base is None else base})")
        if new is None:
            worse.append(f"{name} has no scorecard")
        elif base is not None and new > base:
            worse.append(f"{name}: {new} failures, the last beta had {base}")
    if worse:
        sys.exit("The Gym got worse: " + "; ".join(worse))


if __name__ == "__main__":
    cmd, *rest = sys.argv[1:] or ["help"]
    if cmd == "propose":
        propose(rest[0], rest[1] if len(rest) > 1 and rest[1] else None, rest[2] if len(rest) > 2 and rest[2] else None)
    elif cmd == "pending":
        pending()
    elif cmd == "changelog":
        changelog(rest)
    elif cmd == "soak":
        soak()
    elif cmd == "gym-run":
        gym_run(rest[0] if rest else "", rest[1] if len(rest) > 1 and rest[1] else None)
    elif cmd == "gym":
        gym(*rest)
    else:
        sys.exit(__doc__)
