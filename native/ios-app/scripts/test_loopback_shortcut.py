#!/usr/bin/env python3
import importlib.util
import plistlib
import tempfile
import unittest
from pathlib import Path

SCRIPT_PATH = Path(__file__).with_name("loopback-shortcut.py")
SPEC = importlib.util.spec_from_file_location("loopback_shortcut", SCRIPT_PATH)
MOD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MOD)


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


class LoopbackShortcutTests(unittest.TestCase):
    def test_legacy_workflow_fails_with_index_and_surge_errors(self):
        errors = MOD.validate_workflow(make_legacy_workflow(), name="Poki Loopback")
        joined = "\n".join(errors)
        self.assertIn("hardcodes WFVPN", joined)
        self.assertIn("references Surge", joined)
        self.assertIn("ActionIndex is 1, expected 0", joined)
        self.assertIn("device-specific DefaultValue", joined)

    def test_fix_workflow_clears_hardcoded_vpn_and_fixes_index(self):
        fixed = MOD.fix_workflow(make_legacy_workflow())
        errors = MOD.validate_workflow(fixed, name="Poki Loopback")
        self.assertEqual(errors, [])
        self.assertNotIn("WFVPN", fixed["WFWorkflowActions"][0]["WFWorkflowActionParameters"])
        vpn_q = [q for q in fixed["WFWorkflowImportQuestions"] if q["ParameterKey"] == "WFVPN"][0]
        self.assertEqual(vpn_q["ActionIndex"], 0)
        self.assertNotIn("DefaultValue", vpn_q)

    def test_update_loopback_swift_rejects_legacy_id_and_replaces_valid_id(self):
        with tempfile.TemporaryDirectory() as tmp:
            swift = Path(tmp) / "LoopbackShortcut.swift"
            swift.write_text(
                'private static let shortcut = URL(string: "https://www.icloud.com/shortcuts/cef403d76ef04d0586d03dd69476b96e")!\n',
                encoding="utf-8",
            )
            with self.assertRaises(ValueError):
                MOD.update_loopback_swift(swift, MOD.LEGACY_SHORTCUT_ID)

            new_id = "0123456789abcdef0123456789abcdef"
            updated_url = MOD.update_loopback_swift(
                swift, f"https://www.icloud.com/shortcuts/{new_id}"
            )
            self.assertEqual(updated_url, f"https://www.icloud.com/shortcuts/{new_id}")
            self.assertIn(updated_url, swift.read_text(encoding="utf-8"))
            self.assertNotIn(MOD.LEGACY_SHORTCUT_ID, swift.read_text(encoding="utf-8"))

    def test_committed_signed_shortcut_passes_verification(self):
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


if __name__ == "__main__":
    unittest.main()
