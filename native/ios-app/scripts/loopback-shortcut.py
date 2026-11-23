#!/usr/bin/env python3
"""Build, sign, and verify the Poki Loopback Apple Shortcut."""

from __future__ import annotations

import argparse
import copy
import json
import plistlib
import re
import struct
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

LEGACY_SHORTCUT_ID = "cef403d76ef04d0586d03dd69476b96e"
EXPECTED_SHORTCUT_NAME = "Poki Loopback"
ZERO_UUID = "00000000-0000-0000-0000-000000000000"
NEUTRAL_WFVPN_PLACEHOLDER: dict[str, Any] = {
    "serverAddress": "",
    "title": "VPN",
    "appDescriptor": {
        "BundleIdentifier": "",
        "Name": "",
        "TeamIdentifier": "",
    },
    "identifier": ZERO_UUID,
    "connected": False,
    "onDemandEnabled": False,
}
FORBIDDEN_VPN_CLIENTS = (
    "com.nssurge.inc.surge-ios",
    "com.jkcoxson.localdevvpn",
    "surge",
    "karing",
    "shadowrocket",
    "localdevvpn",
    "stosvpn",
    "stash",
    "loon",
    "quantumult",
    "clash",
)

ICLOUD_URL_RE = re.compile(
    r"^(?:https://www\.icloud\.com/shortcuts/)?([0-9a-fA-F]{32})/?$"
)
SWIFT_LINK_RE = re.compile(
    r"https://www\.icloud\.com/shortcuts/[0-9a-fA-F]{32}"
)

DEFAULT_FIXTURE = (
    Path(__file__).resolve().parent / "fixtures" / "Poki Loopback.shortcut"
)
DEFAULT_SWIFT = (
    Path(__file__).resolve().parents[1]
    / "Poki"
    / "Loopback"
    / "LoopbackShortcut.swift"
)

EXPECTED_ACTION_IDS = [
    "is.workflow.actions.vpn.set",
    "is.workflow.actions.downloadurl",
    "is.workflow.actions.detect.text",
    "is.workflow.actions.conditional",
    "is.workflow.actions.wifi.set",
    "is.workflow.actions.cellulardata.set",
    "is.workflow.actions.downloadurl",
    "is.workflow.actions.cellulardata.set",
    "is.workflow.actions.wifi.set",
    "is.workflow.actions.conditional",
]


def is_neutral_wfvpn_placeholder(value: Any) -> bool:
    """Return True when value is the neutral non-nil WFVPNConfiguration placeholder.

    iOS 27.3 ActionKit's `-[WFVPNConfiguration wfSerializedRepresentation]` crashes
    with SIGABRT during `prepareForSharingWithOptions:` when a WFVPN import question
    has no DefaultValue. A neutral placeholder avoids the crash without binding any
    VPN client or device UUID.
    """
    if not isinstance(value, dict):
        return False
    allowed_keys = {
        "serverAddress",
        "title",
        "appDescriptor",
        "identifier",
        "connected",
        "onDemandEnabled",
    }
    if not set(value.keys()).issubset(allowed_keys):
        return False
    app_desc = value.get("appDescriptor")
    return (
        value.get("serverAddress", "") == ""
        and value.get("title") == "VPN"
        and value.get("identifier") == ZERO_UUID
        and value.get("connected") is False
        and value.get("onDemandEnabled") is False
        and app_desc
        == {"BundleIdentifier": "", "Name": "", "TeamIdentifier": ""}
    )


def extract_shortcut_id(target: str) -> str | None:
    match = ICLOUD_URL_RE.match(target.strip())
    return match.group(1).lower() if match else None


def _curl_bytes(url: str) -> bytes:
    proc = subprocess.run(
        ["curl", "-fsSL", "--max-time", "20", url],
        capture_output=True,
        check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"curl failed ({proc.returncode}) for {url}: "
            f"{proc.stderr.decode('utf-8', errors='replace').strip()}"
        )
    return proc.stdout


def fetch_icloud_record(shortcut_id: str) -> tuple[dict[str, Any], bytes]:
    api_url = f"https://www.icloud.com/shortcuts/api/records/{shortcut_id}"
    record = json.loads(_curl_bytes(api_url).decode("utf-8"))
    fields = record.get("fields", {})
    download_url = fields.get("shortcut", {}).get("value", {}).get("downloadURL")
    if not download_url:
        raise RuntimeError(
            f"iCloud record {shortcut_id} is missing fields.shortcut.value.downloadURL"
        )
    return record, _curl_bytes(download_url)


def decode_shortcut_bytes(raw: bytes) -> tuple[dict[str, Any], str]:
    if raw.startswith(b"AEA1"):
        if len(raw) < 12:
            raise ValueError("Truncated AEA1 shortcut header")
        auth_len = struct.unpack("<I", raw[8:12])[0]
        auth_data = raw[12 : 12 + auth_len]
        auth_pl = plistlib.loads(auth_data)
        chain = auth_pl.get("SigningCertificateChain") or []
        if not chain:
            raise ValueError("AEA1 shortcut missing SigningCertificateChain")
        with tempfile.TemporaryDirectory(prefix="poki_shortcut_aea_") as tmp:
            tmp_dir = Path(tmp)
            aea_path = tmp_dir / "input.shortcut"
            cert_path = tmp_dir / "leaf.der"
            pub_path = tmp_dir / "leaf.pub"
            aar_path = tmp_dir / "payload.aar"
            extract_dir = tmp_dir / "extracted"
            extract_dir.mkdir()
            aea_path.write_bytes(raw)
            cert_path.write_bytes(chain[0])

            openssl = subprocess.run(
                [
                    "openssl",
                    "x509",
                    "-inform",
                    "DER",
                    "-in",
                    str(cert_path),
                    "-pubkey",
                    "-noout",
                    "-out",
                    str(pub_path),
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            if openssl.returncode != 0:
                raise ValueError(f"openssl failed: {openssl.stderr.strip()}")

            decrypt = subprocess.run(
                [
                    "aea",
                    "decrypt",
                    "-i",
                    str(aea_path),
                    "-o",
                    str(aar_path),
                    "-sign-pub",
                    str(pub_path),
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            if decrypt.returncode != 0:
                raise ValueError(f"aea decrypt failed: {decrypt.stderr.strip()}")

            extract = subprocess.run(
                ["aa", "extract", "-i", str(aar_path), "-d", str(extract_dir)],
                capture_output=True,
                text=True,
                check=False,
            )
            if extract.returncode != 0:
                raise ValueError(f"aa extract failed: {extract.stderr.strip()}")

            wflow = extract_dir / "Shortcut.wflow"
            if not wflow.exists():
                raise ValueError("Extracted AEA1 archive missing Shortcut.wflow")
            return plistlib.loads(wflow.read_bytes()), "signed-aea1"

    return plistlib.loads(raw), "unsigned-bplist"


def load_target(target: str) -> tuple[dict[str, Any], dict[str, Any]]:
    shortcut_id = extract_shortcut_id(target)
    if shortcut_id and not Path(target).exists():
        record, raw = fetch_icloud_record(shortcut_id)
        workflow, fmt = decode_shortcut_bytes(raw)
        name = record.get("fields", {}).get("name", {}).get("value")
        return workflow, {
            "source": f"icloud:{shortcut_id}",
            "shortcut_id": shortcut_id,
            "name": name,
            "format": fmt,
            "signing_status": record.get("fields", {})
            .get("signingStatus", {})
            .get("value"),
        }

    path = Path(target)
    raw = path.read_bytes()
    workflow, fmt = decode_shortcut_bytes(raw)
    return workflow, {
        "source": str(path.resolve()),
        "name": path.stem,
        "format": fmt,
    }


def validate_workflow(
    workflow: dict[str, Any],
    *,
    name: str | None = None,
    require_signed_format: str | None = None,
    actual_format: str | None = None,
) -> list[str]:
    errors: list[str] = []

    if name is not None and name != EXPECTED_SHORTCUT_NAME:
        errors.append(
            f"shortcut name is {name!r}, expected {EXPECTED_SHORTCUT_NAME!r}"
        )

    if require_signed_format and actual_format != require_signed_format:
        errors.append(
            f"shortcut format is {actual_format!r}, expected {require_signed_format!r}"
        )

    actions = workflow.get("WFWorkflowActions")
    if not isinstance(actions, list):
        return errors + ["WFWorkflowActions is missing or not a list"]

    action_ids = [a.get("WFWorkflowActionIdentifier") for a in actions]
    if action_ids != EXPECTED_ACTION_IDS:
        errors.append(
            f"WFWorkflowActions identifiers mismatch: got {action_ids}, expected {EXPECTED_ACTION_IDS}"
        )
        return errors

    action0_params = actions[0].get("WFWorkflowActionParameters") or {}
    if "WFVPN" in action0_params and not is_neutral_wfvpn_placeholder(
        action0_params["WFVPN"]
    ):
        errors.append(
            f"WFWorkflowActions[0] hardcodes WFVPN: {action0_params['WFVPN']!r}"
        )
    action0_blob = json.dumps(action0_params, ensure_ascii=False, default=str).lower()
    for client in FORBIDDEN_VPN_CLIENTS:
        if client in action0_blob:
            errors.append(f"WFWorkflowActions[0] still references {client}")
            break

    ready_url = actions[1].get("WFWorkflowActionParameters", {}).get("WFURL")
    if ready_url != "http://127.0.0.1:47684/ready":
        errors.append(f"WFWorkflowActions[1] WFURL is {ready_url!r}")

    cond_params = actions[3].get("WFWorkflowActionParameters", {})
    if (
        cond_params.get("WFControlFlowMode") != 0
        or cond_params.get("WFConditionalActionString") != "false"
    ):
        errors.append(f"WFWorkflowActions[3] conditional mismatch: {cond_params!r}")

    if actions[4].get("WFWorkflowActionParameters", {}).get("OnValue") != 0:
        errors.append("WFWorkflowActions[4] wifi.set should disable Wi-Fi (OnValue=0)")

    if actions[5].get("WFWorkflowActionParameters", {}).get("OnValue") != 0:
        errors.append(
            "WFWorkflowActions[5] cellulardata.set should disable Cellular (OnValue=0)"
        )

    reconnect_url = actions[6].get("WFWorkflowActionParameters", {}).get("WFURL")
    if reconnect_url != "http://127.0.0.1:47684/reconnect":
        errors.append(f"WFWorkflowActions[6] WFURL is {reconnect_url!r}")

    if actions[7].get("WFWorkflowActionParameters", {}).get("OnValue") != 1:
        errors.append(
            "WFWorkflowActions[7] cellulardata.set should re-enable Cellular (OnValue=1)"
        )

    if actions[9].get("WFWorkflowActionParameters", {}).get("WFControlFlowMode") != 2:
        errors.append("WFWorkflowActions[9] conditional end missing WFControlFlowMode=2")

    triggers = workflow.get("WFWorkflowTriggers") or []
    wifi_triggers = [
        t for t in triggers if t.get("WFTriggerIdentifier") == "WFWifiTrigger"
    ]
    if len(wifi_triggers) != 1:
        errors.append(f"expected 1 WFWifiTrigger, found {len(wifi_triggers)}")
        trigger_uuid = None
    else:
        trigger_uuid = wifi_triggers[0].get("WFTriggerUUID")
        conn_type = wifi_triggers[0].get("WFTriggerSerializedParameters", {}).get(
            "WFConnectionType"
        )
        if conn_type != "disconnected":
            errors.append(f"WFWifiTrigger WFConnectionType is {conn_type!r}")

    questions = workflow.get("WFWorkflowImportQuestions")
    if not isinstance(questions, list):
        return errors + ["WFWorkflowImportQuestions is missing or not a list"]

    vpn_questions = [q for q in questions if q.get("ParameterKey") == "WFVPN"]
    if len(vpn_questions) != 1:
        errors.append(
            f"expected 1 WFVPN import question, found {len(vpn_questions)}"
        )
    else:
        vq = vpn_questions[0]
        if vq.get("Category") != "Parameter":
            errors.append(f"WFVPN import question Category is {vq.get('Category')!r}")
        if vq.get("ActionIndex") != 0:
            errors.append(
                f"WFVPN import question ActionIndex is {vq.get('ActionIndex')!r}, expected 0"
            )
        if "DefaultValue" not in vq:
            errors.append(
                "WFVPN import question missing neutral DefaultValue placeholder (crashes iOS 27.3 Shortcuts on share)"
            )
        elif not is_neutral_wfvpn_placeholder(vq["DefaultValue"]):
            errors.append(
                f"WFVPN import question carries non-neutral DefaultValue: {vq['DefaultValue']!r}"
            )

    by_key = {q.get("ParameterKey"): q for q in questions}
    for key in ("__enabled__", "__show_confirmation__"):
        tq = by_key.get(key)
        if not tq or tq.get("Category") != "Trigger":
            errors.append(f"missing Trigger import question {key!r}")
        elif trigger_uuid and tq.get("TriggerUUID") != trigger_uuid:
            errors.append(f"Trigger import question {key!r} TriggerUUID mismatch")

    return errors


def fix_workflow(workflow: dict[str, Any]) -> dict[str, Any]:
    fixed = copy.deepcopy(workflow)
    actions = fixed.get("WFWorkflowActions") or []
    if not actions or actions[0].get("WFWorkflowActionIdentifier") != "is.workflow.actions.vpn.set":
        raise ValueError("Source workflow does not start with is.workflow.actions.vpn.set")

    params0 = actions[0].setdefault("WFWorkflowActionParameters", {})
    params0.pop("WFVPN", None)

    vpn_fixed = False
    for question in fixed.get("WFWorkflowImportQuestions") or []:
        if question.get("ParameterKey") == "WFVPN":
            question["ActionIndex"] = 0
            question["DefaultValue"] = copy.deepcopy(NEUTRAL_WFVPN_PLACEHOLDER)
            vpn_fixed = True

    if not vpn_fixed:
        raise ValueError("Source workflow is missing WFVPN import question")

    errors = validate_workflow(fixed)
    if errors:
        raise ValueError(f"Fixed workflow failed validation: {errors}")
    return fixed


def sign_shortcut(unsigned_path: Path, signed_path: Path) -> None:
    proc = subprocess.run(
        [
            "/usr/bin/shortcuts",
            "sign",
            "--mode",
            "anyone",
            "--input",
            str(unsigned_path),
            "--output",
            str(signed_path),
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"shortcuts sign failed ({proc.returncode}): {proc.stderr.strip()}"
        )


def _wfvpn_state(container: dict[str, Any], key: str) -> str:
    if key not in container:
        return "absent"
    if is_neutral_wfvpn_placeholder(container[key]):
        return "neutral-placeholder"
    return "hardcoded"


def summarize(workflow: dict[str, Any], meta: dict[str, Any]) -> dict[str, Any]:
    vpn_q = next(
        (
            q
            for q in workflow.get("WFWorkflowImportQuestions") or []
            if q.get("ParameterKey") == "WFVPN"
        ),
        None,
    )
    action0 = (workflow.get("WFWorkflowActions") or [{}])[0]
    params0 = action0.get("WFWorkflowActionParameters") or {}
    return {
        "source": meta.get("source"),
        "name": meta.get("name"),
        "format": meta.get("format"),
        "signing_status": meta.get("signing_status"),
        "action_count": len(workflow.get("WFWorkflowActions") or []),
        "action0_identifier": action0.get("WFWorkflowActionIdentifier"),
        "action0_wfvpn_state": _wfvpn_state(params0, "WFVPN"),
        "wfvpn_question_action_index": vpn_q.get("ActionIndex") if vpn_q else None,
        "wfvpn_question_default_state": _wfvpn_state(vpn_q, "DefaultValue")
        if vpn_q
        else None,
        "trigger_count": len(workflow.get("WFWorkflowTriggers") or []),
    }


def update_loopback_swift(swift_path: Path, shortcut_id: str) -> str:
    clean_id = extract_shortcut_id(shortcut_id)
    if not clean_id:
        raise ValueError(f"Invalid iCloud shortcut ID or URL: {shortcut_id!r}")
    if clean_id == LEGACY_SHORTCUT_ID:
        raise ValueError(f"Refusing to reuse legacy shortcut ID {LEGACY_SHORTCUT_ID}")

    text = swift_path.read_text(encoding="utf-8")
    new_url = f"https://www.icloud.com/shortcuts/{clean_id}"
    updated, count = SWIFT_LINK_RE.subn(new_url, text)
    if count != 1:
        raise ValueError(
            f"Expected 1 iCloud shortcut URL in {swift_path}, found {count}"
        )
    swift_path.write_text(updated, encoding="utf-8")
    return new_url


def cmd_verify(args: argparse.Namespace) -> int:
    workflow, meta = load_target(args.target)
    errors = validate_workflow(
        workflow,
        name=meta.get("name"),
        require_signed_format="signed-aea1" if args.require_signed else None,
        actual_format=meta.get("format"),
    )
    payload = {
        "ok": not errors,
        "summary": summarize(workflow, meta),
        "errors": errors,
    }
    print(json.dumps(payload, indent=2, ensure_ascii=False))
    return 0 if not errors else 1


def cmd_build(args: argparse.Namespace) -> int:
    workflow, _ = load_target(args.source)
    fixed = fix_workflow(workflow)
    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)

    if args.sign:
        with tempfile.TemporaryDirectory(prefix="poki_shortcut_build_") as tmp:
            unsigned_path = Path(tmp) / f"unsigned-{output_path.name}"
            signed_tmp = Path(tmp) / output_path.name
            unsigned_path.write_bytes(plistlib.dumps(fixed, fmt=plistlib.FMT_BINARY))
            sign_shortcut(unsigned_path, signed_tmp)
            output_path.write_bytes(signed_tmp.read_bytes())
    else:
        output_path.write_bytes(plistlib.dumps(fixed, fmt=plistlib.FMT_BINARY))

    verified_workflow, meta = load_target(str(output_path))
    errors = validate_workflow(
        verified_workflow,
        name=meta.get("name"),
        require_signed_format="signed-aea1" if args.sign else None,
        actual_format=meta.get("format"),
    )
    if errors:
        raise RuntimeError(f"Built artifact failed verification: {errors}")

    print(
        json.dumps(
            {"ok": True, "summary": summarize(verified_workflow, meta)},
            indent=2,
            ensure_ascii=False,
        )
    )
    return 0


def cmd_update_app(args: argparse.Namespace) -> int:
    shortcut_id = extract_shortcut_id(args.target)
    if not shortcut_id:
        raise SystemExit(f"Invalid iCloud shortcut ID or URL: {args.target!r}")
    if shortcut_id == LEGACY_SHORTCUT_ID:
        raise SystemExit(f"Refusing to reuse legacy shortcut ID {LEGACY_SHORTCUT_ID}")

    workflow, meta = load_target(shortcut_id)
    errors = validate_workflow(workflow, name=meta.get("name"))
    if errors:
        print(
            json.dumps(
                {"ok": False, "summary": summarize(workflow, meta), "errors": errors},
                indent=2,
                ensure_ascii=False,
            )
        )
        return 1

    new_url = update_loopback_swift(Path(args.swift_file), shortcut_id)
    print(
        json.dumps(
            {
                "ok": True,
                "updated_url": new_url,
                "swift_file": str(Path(args.swift_file).resolve()),
                "summary": summarize(workflow, meta),
            },
            indent=2,
            ensure_ascii=False,
        )
    )
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    p_verify = sub.add_parser("verify", help="Verify a local .shortcut file or iCloud link/ID")
    p_verify.add_argument("target", nargs="?", default=str(DEFAULT_FIXTURE))
    p_verify.add_argument(
        "--require-signed",
        action="store_true",
        help="Require Apple AEA1 signature (shortcuts sign --mode anyone)",
    )
    p_verify.set_defaults(func=cmd_verify)

    p_build = sub.add_parser("build", help="Generate fixed Poki Loopback .shortcut from a source")
    p_build.add_argument("--source", default=LEGACY_SHORTCUT_ID)
    p_build.add_argument("--output", default=str(DEFAULT_FIXTURE))
    p_build.add_argument(
        "--sign",
        action="store_true",
        help="Notarize with `shortcuts sign --mode anyone`",
    )
    p_build.set_defaults(func=cmd_build)

    p_update = sub.add_parser(
        "update-app",
        help="Verify a new public iCloud link and replace LoopbackShortcut.swift",
    )
    p_update.add_argument("target", help="New iCloud shortcut URL or 32-hex ID")
    p_update.add_argument("--swift-file", default=str(DEFAULT_SWIFT))
    p_update.set_defaults(func=cmd_update_app)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
