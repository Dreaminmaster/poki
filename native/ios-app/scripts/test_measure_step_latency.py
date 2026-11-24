#!/usr/bin/env python3
import importlib.util
import json
import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPT_PATH = Path(__file__).with_name("measure-step-latency.py")
SPEC = importlib.util.spec_from_file_location("measure_step_latency", SCRIPT_PATH)
MOD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MOD)


class MeasureStepLatencyIsolationTests(unittest.TestCase):
    def test_cli_rejects_external_udid_flag(self):
        proc = subprocess.run(
            [
                sys.executable,
                str(SCRIPT_PATH),
                "--udid", "EXISTING-SIM-UDID",
                "--target", "fix=abc=/tmp/Poki.app",
                "--out", "/tmp/out",
            ],
            text=True,
            capture_output=True,
            timeout=10,
        )
        self.assertEqual(proc.returncode, 2, proc.stderr)
        self.assertIn("unrecognized arguments: --udid", proc.stderr)

    def test_run_one_refuses_unowned_simulator_without_modifying_container(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            app = root / "Poki.app"
            app.mkdir()
            (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "nz.zheha.poki"}))

            container = root / "container"
            mem_file = container / "Library/Application Support/Poki/agent-memory.json"
            mem_file.parent.mkdir(parents=True)
            original_mem = json.dumps({"schema": "poki.agent-memory/2", "notes": [{"id": "keep-me"}]})
            mem_file.write_text(original_mem)

            session_file = container / "Library/Application Support/Poki/Sessions/s1.json"
            session_file.parent.mkdir(parents=True)
            session_file.write_text('{"id":"s1"}')

            backup_file = container / "Documents/AgentBackup/b1.json"
            backup_file.parent.mkdir(parents=True)
            backup_file.write_text('{"id":"b1"}')

            def fake_sim(*args, **kwargs):
                if args and args[0] == "get_app_container":
                    return str(container) + "\n"
                return ""

            dummy_server = mock.MagicMock()
            dummy_server.server_port = 12345

            with mock.patch.object(MOD, "sim", side_effect=fake_sim):
                with self.assertRaises(ValueError):
                    MOD.run_one(
                        dummy_server,
                        "EXTERNAL-SIM-UDID",
                        app,
                        "label",
                        "sha",
                        "web",
                        "empty",
                        0,
                        root / "out",
                        developer_dir="/Applications/Xcode.app/Contents/Developer",
                    )

            self.assertEqual(mem_file.read_text(), original_mem)
            self.assertTrue(session_file.exists())
            self.assertTrue(backup_file.exists())

    def test_ephemeral_simulator_creates_boots_and_deletes_on_failure(self):
        calls = []

        def fake_sim(*args, **kwargs):
            calls.append(args)
            if args[0] == "create":
                return "NEW-TEMP-UDID\n"
            return ""

        with mock.patch.object(MOD, "sim", side_effect=fake_sim):
            with self.assertRaises(RuntimeError):
                with MOD.ephemeral_simulator(
                    device_type="com.apple.CoreSimulator.SimDeviceType.iPhone-17",
                    runtime="com.apple.CoreSimulator.SimRuntime.iOS-27-2",
                ) as udid:
                    self.assertEqual(udid, "NEW-TEMP-UDID")
                    self.assertIn(udid, MOD.OWNED_SIMULATORS)
                    raise RuntimeError("boom")

        self.assertNotIn("NEW-TEMP-UDID", MOD.OWNED_SIMULATORS)
        verbs = [c[0] for c in calls]
        self.assertEqual(verbs, ["create", "boot", "bootstatus", "shutdown", "delete"])
        self.assertEqual(calls[-1][1], "NEW-TEMP-UDID")

    def test_unknown_memory_profile_raises_value_error(self):
        with self.assertRaises(ValueError):
            MOD.make_memory_file("phone_shape")

    def test_settings_run_stopping_on_general_page_is_marked_failed(self):
        general_screen = (
            'app: 设置   read: 2026-11-21T17:07:40Z (422 ms)\n'
            'elements (10):\n'
            '+31 NavigationBar "通用" [0,62,402,54]\n'
            '+36 Button "关于本机" [16,386,370,52]\n'
            '+37 Button "屏幕捕捉" [16,473,370,52]\n'
        )
        state = {"task": "settings"}
        # Turn 3 receives the General page: must tap "关于本机" (ref 36), never just call look.
        tool, payload = MOD.decide_action(
            "settings", 3, [{"role": "tool", "content": general_screen}], state
        )
        self.assertEqual(tool, "do", f"Expected tap on About button, got {tool} {payload}")
        self.assertEqual(payload, {"actions": [{"tap": 36}]})

        # Even if turn 4 still sees the General page (About never opened), evaluation must fail.
        tool4, payload4 = MOD.decide_action(
            "settings", 4, [{"role": "tool", "content": general_screen}], state
        )
        self.assertEqual(tool4, "finish_task")
        self.assertFalse(payload4["success"], "Must not report success=True when About page was never reached")

        err = MOD.evaluate_run_result(
            "settings",
            turns=[{"turn": i} for i in range(6)],
            state=state,
            probe_item={"step": "chat", "ok": True},
        )
        self.assertIsNotNone(err, "Run that never reached About page must be marked failed")

    def test_tool_error_or_rejected_finish_task_is_marked_failed(self):
        about_screen = (
            'app: 设置   read: 2026-11-21T17:07:41Z (320 ms)\n'
            'elements (8):\n'
            '+50 NavigationBar "关于本机" [0,62,402,54]\n'
            '+51 Button "名称, iPhone" [16,160,370,44]\n'
            '+52 Button "iOS版本, 27.2" [16,204,370,44]\n'
            '+53 StaticText "型号名称" [16,248,120,24]\n'
        )
        state = {"task": "settings", "saw_settings": True, "saw_general": True}
        tool4, payload4 = MOD.decide_action(
            "settings", 4, [{"role": "tool", "content": about_screen}], state
        )
        self.assertEqual(tool4, "finish_task")
        self.assertTrue(payload4["success"])

        # Turn 5 receives a rejected / failed finish_task tool receipt.
        MOD.decide_action(
            "settings",
            5,
            [{"role": "tool", "content": "error: finish_task rejected by harness"}],
            state,
        )
        err = MOD.evaluate_run_result(
            "settings",
            turns=[{"turn": i} for i in range(6)],
            state=state,
            probe_item={"step": "chat", "ok": True},
        )
        self.assertIsNotNone(err, "Run whose finish_task returned an error must be marked failed")

    def test_failed_samples_are_retained_and_listed_separately(self):
        with tempfile.TemporaryDirectory() as tmp:
            db_path = Path(tmp) / "results.sqlite"
            conn = MOD.init_db(db_path)
            base_row = {
                "commit_sha": "abc1234",
                "task": "settings",
                "profile": "empty",
                "task_total_ms": 5000.0,
                "step_interval_median_ms": 400.0,
                "step_interval_min_ms": 380.0,
                "step_interval_max_ms": 420.0,
                "tool_ms_median": 300.0,
                "client_overhead_median_ms": 100.0,
                "wire_bytes_median": 100000.0,
                "tokens_median": 8000.0,
                "system_bytes": 14000,
                "base_system_bytes": 10000,
                "reply_examples_bytes": 0,
                "counted_scroll_bytes": 1834,
                "memory_attr_bytes": 337,
                "embedded_tool_prose_bytes": 2000,
                "memories_bytes": 0,
                "skills_bytes": 593,
                "tools_bytes": 16179,
                "finish_task_bytes": 1549,
                "finish_task_card_bytes": 0,
                "count_messages_bytes": 968,
                "app_memory_brief_max_bytes": 0,
                "screen_text_max_bytes": 5000,
                "screen_image_max_count": 3,
                "screen_image_max_b64_bytes": 120000,
                "finish_task_rejected": 0,
                "turns": [],
            }
            ok_row = {**base_row, "run_id": "r00_split_settings", "label": "split", "round_idx": 0, "ok": 1, "error": ""}
            fail_row = {
                **base_row,
                "run_id": "r01_split_settings",
                "label": "split",
                "round_idx": 1,
                "ok": 0,
                "error": "about page never observed in Settings",
            }
            MOD.save_row(conn, ok_row)
            MOD.save_row(conn, fail_row)
            saved = conn.execute("SELECT run_id, ok, error FROM runs ORDER BY run_id").fetchall()
            conn.close()
            self.assertEqual(
                saved,
                [
                    ("r00_split_settings", 1, ""),
                    ("r01_split_settings", 0, "about page never observed in Settings"),
                ],
            )
            summary = MOD.format_run_summary([ok_row, fail_row])
            self.assertIn("ok=1/2", summary)
            self.assertIn("failed=1", summary)
            self.assertIn("r01_split_settings", summary)
            self.assertIn("about page never observed in Settings", summary)

    def test_photos_dismisses_onboarding_and_notification_alert_before_finishing(self):
        splash_screen = (
            'app: 照片   read: 2026-11-21T18:57:51Z (351 ms)\n'
            'elements (6):\n'
            ' 1 StaticText "“照片”新功能" [38,135,326,26]\n'
            ' 6 Button "继续" [38,784,326,52]\n'
        )
        alert_screen = (
            'app: Home screen (SpringBoard: the home screen, the App Switcher, a banner or a system alert)   '
            'read: 2026-11-21T18:57:55Z (336 ms)   note: the tree lists the alert only, not the screen behind it\n'
            'elements (8):\n'
            ' 1 Alert "“照片”想给你发送通知" [41,365,320,172]\n'
            ' 5 Button "不允许" [57,473,140,48]\n'
            ' 6 Button "允许" [205,473,140,48]\n'
        )
        library_screen = (
            'app: 照片   read: 2026-11-21T18:57:53Z (420 ms)\n'
            'elements (26):\n'
            ' 1 NavigationBar "PXCuratedLibraryUIView" [0,62,402,54]\n'
            ' 2 Other "图库, 6 Photos" [16,46,65,77]\n'
            ' 4 Button "选择" [324,66,58,36]\n'
        )
        unchanged_after_swipe = (
            'app: 照片   read: 2026-11-21T18:57:56Z (300 ms)\n'
            'did: swipe up from [201, 680] to [201, 163] (sent, 850 ms)\n'
            'screen_changed: false\n'
            'elements: none changed (26 on screen keep their numbers)\n'
        )

        # Case 1: Alert popping up on turn 4 must NEVER be mistaken for Photos library;
        # it must be dismissed by tapping "不允许" (ref 5) instead of finishing with success=True.
        state = {"task": "photos"}
        t2, p2 = MOD.decide_action("photos", 2, [{"role": "tool", "content": splash_screen}], state)
        self.assertEqual((t2, p2), ("do", {"actions": [{"tap": 6}]}))
        t3, p3 = MOD.decide_action("photos", 3, [{"role": "tool", "content": library_screen}], state)
        self.assertEqual((t3, p3), ("do", {"actions": [{"swipe": "up"}]}))
        t4, p4 = MOD.decide_action("photos", 4, [{"role": "tool", "content": alert_screen}], state)
        self.assertEqual((t4, p4), ("do", {"actions": [{"tap": 5}]}))
        t5, p5 = MOD.decide_action("photos", 5, [{"role": "tool", "content": unchanged_after_swipe}], state)
        self.assertEqual(t5, "finish_task")
        self.assertTrue(p5["success"])
        t6, _ = MOD.decide_action("photos", 6, [{"role": "tool", "content": "Result recorded. Done."}], state)
        self.assertIsNone(t6)
        self.assertIsNone(
            MOD.evaluate_run_result("photos", turns=[{"turn": i} for i in range(7)], state=state)
        )

        # Case 2: If the alert never clears (turns exhausted), evaluation must mark failed.
        stuck_state = {"task": "photos"}
        MOD.decide_action("photos", 2, [{"role": "tool", "content": alert_screen}], stuck_state)
        self.assertIsNotNone(
            MOD.evaluate_run_result("photos", turns=[{"turn": i} for i in range(6)], state=stuck_state)
        )


if __name__ == "__main__":
    unittest.main()
