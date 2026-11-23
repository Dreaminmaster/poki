#!/usr/bin/env python3
import copy
import importlib.util
import json
import struct
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPT_PATH = Path(__file__).with_name("loopback-shortcut.py")
SPEC = importlib.util.spec_from_file_location("loopback_shortcut", SCRIPT_PATH)
MOD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MOD)

LEGACY_ID = "cef403d76ef04d0586d03dd69476b96e"
EXPECTED_LIVE_URL = (
    "https://www.icloud.com/shortcuts/f8ff9cd906194fbf8a58ed51137f6c0a"
)
EXPECTED_NEUTRAL_WFVPN = {
    "serverAddress": "",
    "title": "VPN",
    "appDescriptor": {
        "BundleIdentifier": "",
        "Name": "",
        "TeamIdentifier": "",
    },
    "identifier": "00000000-0000-0000-0000-000000000000",
    "connected": False,
    "onDemandEnabled": False,
}


def make_legacy_workflow() -> dict:
    return {
        "WFWorkflowTriggers": [
            {
                "WFTriggerSerializedParameters": {
                    "WFConnectionType": "disconnected",
                    "WFRunAfterConnectionInterruption": True,
                },
                "WFTriggerIdentifier": "WFWifiTrigger",
                "WFTriggerUUID": "4D26E5C8-B7C8-432D-84C1-C91412451426",
            }
        ],
        "WFWorkflowActions": [
            {
                "WFWorkflowActionIdentifier": "is.workflow.actions.vpn.set",
                "WFWorkflowActionParameters": {
                    "WFVPN": {
                        "serverAddress": "Surge",
                        "title": "Surge",
                        "appDescriptor": {
                            "BundleIdentifier": "com.nssurge.inc.surge-ios",
                            "Name": "Surge",
                            "TeamIdentifier": "YCKFLA6N72",
                        },
                        "identifier": "8D3A8AC8-3C64-4DAA-AFDE-41B8A60AB226",
                        "connected": True,
                        "onDemandEnabled": True,
                    },
                    "UUID": "382B2989-52DB-403B-99BF-9E8094028369",
                },
            },
            {
                "WFWorkflowActionIdentifier": "is.workflow.actions.downloadurl",
                "WFWorkflowActionParameters": {
                    "WFURL": "http://127.0.0.1:47684/ready",
                    "UUID": "CCCC5657-AF72-4EBE-B251-DDB0143A2843",
                    "ShowHeaders": False,
                },
            },
            {
                "WFWorkflowActionIdentifier": "is.workflow.actions.detect.text",
                "WFWorkflowActionParameters": {},
            },
            {
                "WFWorkflowActionIdentifier": "is.workflow.actions.conditional",
                "WFWorkflowActionParameters": {
                    "WFControlFlowMode": 0,
                    "WFConditionalActionString": "false",
                },
            },
            {
                "WFWorkflowActionIdentifier": "is.workflow.actions.wifi.set",
                "WFWorkflowActionParameters": {"OnValue": 0, "ShowWhenRun": False},
            },
            {
                "WFWorkflowActionIdentifier": "is.workflow.actions.cellulardata.set",
                "WFWorkflowActionParameters": {"OnValue": 0, "ShowWhenRun": False},
            },
            {
                "WFWorkflowActionIdentifier": "is.workflow.actions.downloadurl",
                "WFWorkflowActionParameters": {
                    "WFURL": "http://127.0.0.1:47684/reconnect",
                    "UUID": "7E68DD0A-61FD-4726-B781-6B4AC8A18AED",
                    "ShowHeaders": False,
                },
            },
            {
                "WFWorkflowActionIdentifier": "is.workflow.actions.cellulardata.set",
                "WFWorkflowActionParameters": {"OnValue": 1, "ShowWhenRun": False},
            },
            {
                "WFWorkflowActionIdentifier": "is.workflow.actions.wifi.set",
                "WFWorkflowActionParameters": {"ShowWhenRun": False},
            },
            {
                "WFWorkflowActionIdentifier": "is.workflow.actions.conditional",
                "WFWorkflowActionParameters": {"WFControlFlowMode": 2},
            },
        ],
        "WFWorkflowImportQuestions": [
            {
                "ParameterKey": "__enabled__",
                "Category": "Trigger",
                "Text": "Please turn on Automation 请开启自动化",
                "TriggerUUID": "4D26E5C8-B7C8-432D-84C1-C91412451426",
                "DefaultValue": True,
            },
            {
                "ParameterKey": "__show_confirmation__",
                "Category": "Trigger",
                "Text": "Please make sure “Confirm Before Run” is off 请检查已关闭“运行时确认”选项",
                "TriggerUUID": "4D26E5C8-B7C8-432D-84C1-C91412451426",
            },
            {
                "ParameterKey": "WFVPN",
                "Category": "Parameter",
                "ActionIndex": 1,
                "Text": "Please choose the VPN App used for loopback connections 请选择用于回环连接的 VPN 应用",
                "DefaultValue": {
                    "serverAddress": "LocalDevVPN's Local Network Tunnel",
                    "title": "LocalDevVPN",
                    "appDescriptor": {
                        "BundleIdentifier": "com.jkcoxson.LocalDevVPN",
                        "Name": "LocalDevVPN",
                        "TeamIdentifier": "42Q7QX86GV",
                    },
                    "identifier": "D7C1B708-9D75-454B-9221-98BAADC5541C",
                    "connected": False,
                    "onDemandEnabled": True,
                },
            },
        ],
    }


def wfvpn_question(workflow: dict) -> dict:
    return [
        q for q in workflow["WFWorkflowImportQuestions"] if q["ParameterKey"] == "WFVPN"
    ][0]


class LoopbackShortcutTests(unittest.TestCase):
    def test_legacy_workflow_fails_with_index_and_surge_errors(self):
        errors = MOD.validate_workflow(make_legacy_workflow(), name="Poki Loopback")
        joined = "\n".join(errors)
        self.assertIn("hardcodes WFVPN", joined)
        self.assertIn("references com.nssurge.inc.surge-ios", joined)
        self.assertIn("ActionIndex is 1, expected 0", joined)
        self.assertIn("non-neutral DefaultValue", joined)

    def test_missing_default_value_fails_to_prevent_ios27_share_crash(self):
        fixed = MOD.fix_workflow(make_legacy_workflow())
        wfvpn_question(fixed).pop("DefaultValue")
        errors = MOD.validate_workflow(fixed, name="Poki Loopback")
        self.assertTrue(
            any("missing neutral DefaultValue placeholder" in e for e in errors),
            errors,
        )

    def test_fix_workflow_sets_neutral_placeholder_and_index_zero(self):
        fixed = MOD.fix_workflow(make_legacy_workflow())
        errors = MOD.validate_workflow(fixed, name="Poki Loopback")
        self.assertEqual(errors, [])
        self.assertNotIn(
            "WFVPN", fixed["WFWorkflowActions"][0]["WFWorkflowActionParameters"]
        )
        vpn_q = wfvpn_question(fixed)
        self.assertEqual(vpn_q["ActionIndex"], 0)
        self.assertEqual(vpn_q["DefaultValue"], EXPECTED_NEUTRAL_WFVPN)

    def test_icloud_exported_neutral_placeholder_in_action0_is_accepted(self):
        exported = MOD.fix_workflow(make_legacy_workflow())
        neutral_action0 = copy.deepcopy(EXPECTED_NEUTRAL_WFVPN)
        neutral_action0.pop("serverAddress")
        exported["WFWorkflowActions"][0]["WFWorkflowActionParameters"][
            "WFVPN"
        ] = neutral_action0
        self.assertEqual(MOD.validate_workflow(exported, name="Poki Loopback"), [])

        bad = copy.deepcopy(exported)
        bad["WFWorkflowActions"][0]["WFWorkflowActionParameters"]["WFVPN"][
            "title"
        ] = "Karing"
        errors = MOD.validate_workflow(bad, name="Poki Loopback")
        self.assertTrue(any("hardcodes WFVPN" in e for e in errors), errors)

    def test_icloud_signing_status_must_be_approved(self):
        fixed = MOD.fix_workflow(make_legacy_workflow())
        self.assertEqual(
            MOD.validate_workflow(
                fixed,
                name="Poki Loopback",
                require_signing_status="APPROVED",
                actual_signing_status="APPROVED",
            ),
            [],
        )
        errors = MOD.validate_workflow(
            fixed,
            name="Poki Loopback",
            require_signing_status="APPROVED",
            actual_signing_status="PENDING",
        )
        self.assertTrue(
            any("signingStatus is 'PENDING', expected 'APPROVED'" in e for e in errors),
            errors,
        )

    def test_decode_rejects_truncated_aea1_auth_len_and_null_icloud_fields(self):
        truncated = b"AEA1\x00\x00\x00\x00" + struct.pack("<I", 9999) + b"short"
        with self.assertRaisesRegex(ValueError, "Truncated AEA1 auth header"):
            MOD.decode_shortcut_bytes(truncated)

        null_record = json.dumps({"fields": {"shortcut": None}}).encode("utf-8")
        with mock.patch.object(MOD, "_curl_bytes", return_value=null_record):
            with self.assertRaisesRegex(
                RuntimeError, "missing fields.shortcut.value.downloadURL"
            ):
                MOD.fetch_icloud_record("0123456789abcdef0123456789abcdef")

    def test_update_loopback_swift_rejects_legacy_id_and_replaces_valid_id(self):
        with tempfile.TemporaryDirectory() as tmp:
            swift = Path(tmp) / "LoopbackShortcut.swift"
            swift.write_text(
                f'private static let shortcut = URL(string: "https://www.icloud.com/shortcuts/{LEGACY_ID}")!\n',
                encoding="utf-8",
            )
            with self.assertRaisesRegex(ValueError, "legacy"):
                MOD.update_loopback_swift(swift, LEGACY_ID)

            new_id = "0123456789abcdef0123456789abcdef"
            updated_url = MOD.update_loopback_swift(
                swift, f"https://www.icloud.com/shortcuts/{new_id}"
            )
            self.assertEqual(updated_url, f"https://www.icloud.com/shortcuts/{new_id}")
            self.assertIn(updated_url, swift.read_text(encoding="utf-8"))
            self.assertNotIn(LEGACY_ID, swift.read_text(encoding="utf-8"))

    def test_committed_signed_shortcut_and_app_url_pass_verification(self):
        self.assertTrue(
            MOD.DEFAULT_FIXTURE.exists(),
            f"missing committed signed shortcut at {MOD.DEFAULT_FIXTURE}",
        )
        workflow, meta = MOD.load_target(str(MOD.DEFAULT_FIXTURE))
        errors = MOD.validate_workflow(
            workflow,
            name=meta.get("name"),
            require_signed_format="signed-aea1",
            actual_format=meta.get("format"),
        )
        self.assertEqual(errors, [])

        swift_text = MOD.DEFAULT_SWIFT.read_text(encoding="utf-8")
        self.assertNotIn(LEGACY_ID, swift_text)
        self.assertIn(EXPECTED_LIVE_URL, swift_text)


if __name__ == "__main__":
    unittest.main()
