#!/usr/bin/env python3
import importlib.util
import json
import socket
import tempfile
import threading
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("jabridge_ipc", ROOT / "bin" / "jabridge_ipc.py")
bridge = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(bridge)


class FakeServer:
    def __init__(self, handler):
        self.directory = tempfile.TemporaryDirectory()
        self.path = Path(self.directory.name) / "jabridge.sock"
        self.handler = handler
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(str(self.path))
        self.server.listen(1)
        self.thread = threading.Thread(target=self.run, daemon=True)
        self.thread.start()

    def run(self):
        connection, _ = self.server.accept()
        try:
            with connection, connection.makefile("rb") as reader:
                for line in reader:
                    request = json.loads(line)
                    result = self.handler(request)
                    if isinstance(result, list) and result and result[0] in ("notification", "notifications"):
                        notifications = result[1] if result[0] == "notifications" else [result[1]]
                        result = result[2]
                        for notification in notifications:
                            connection.sendall(json.dumps(notification).encode() + b"\n")
                    response = {"jsonrpc": "2.0", "id": request["id"]}
                    if isinstance(result, Exception):
                        response["error"] = {"code": -32000, "message": str(result)}
                    else:
                        response["result"] = result
                    connection.sendall(json.dumps(response).encode() + b"\n")
        except (BrokenPipeError, ConnectionResetError):
            pass

    def close(self):
        self.server.close()
        self.thread.join(timeout=1)
        self.directory.cleanup()

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()


DEVICES = [
    {"id": 0, "name": "Jabra Link 380", "isDongle": True, "selected": True, "firmware": "1.16.0"},
    {"id": 1, "name": "Jabra Evolve2 85", "isDongle": False, "selected": True,
     "connection": "dongle", "firmware": "1.5.7", "battery": {"level": 94, "charging": False}},
]
SETTINGS = [{
    "device": "headset", "key": "noise-control", "label": "Noise control", "value": "Off",
    "editable": True, "choices": ["Off", "HearThrough", "ANC"], "kind": "choice",
    "target": {"id": 1, "instance": "a" * 32},
}]
SOUND = {"available": True, "inCall": False, "nodes": [{
    "kind": "output", "default": True, "editable": True, "volume": 55, "muted": False,
    "audioMode": "calls", "modes": ["music", "calls"], "target": {"id": 61, "token": "b" * 64},
}]}


class BridgeTests(unittest.TestCase):
    def test_snapshot_selects_headset_dongle_battery_and_sound(self):
        def handler(request):
            return {"devices.list": DEVICES, "settings.list": SETTINGS, "sound.list": SOUND}[request["method"]]

        with FakeServer(handler) as fake, bridge.RpcClient(fake.path) as client:
            value = bridge.snapshot(client)
        self.assertTrue(value["connected"])
        self.assertEqual(value["device"]["name"], "Jabra Evolve2 85")
        self.assertEqual(value["dongle"]["firmware"], "1.16.0")
        self.assertEqual(value["battery"]["level"], 94)
        self.assertEqual(value["output"]["volume"], 55)

    def test_rpc_ignores_notification_while_waiting_for_reply(self):
        def handler(request):
            return ["notification", {"jsonrpc": "2.0", "method": "sound.changed"}, {"ready": True}]

        with FakeServer(handler) as fake, bridge.RpcClient(fake.path) as client:
            value = client.call("service.ping")
            self.assertEqual(value, {"ready": True})
            self.assertFalse(hasattr(client, "notifications"))

    def test_rpc_call_rejects_notification_flood(self):
        def handler(request):
            notifications = [
                {"jsonrpc": "2.0", "method": "sound.changed", "params": {"index": index}}
                for index in range(4)
            ]
            return ["notifications", notifications, {"ready": True}]

        original_limit = bridge.MAX_RPC_MESSAGES_PER_CALL
        bridge.MAX_RPC_MESSAGES_PER_CALL = 3
        try:
            with FakeServer(handler) as fake, bridge.RpcClient(fake.path) as client:
                with self.assertRaisesRegex(bridge.BridgeError, "exceeded 3 messages"):
                    client.call("service.ping")
                self.assertFalse(hasattr(client, "notifications"))

        finally:
            bridge.MAX_RPC_MESSAGES_PER_CALL = original_limit

    def test_rpc_call_enforces_wall_clock_deadline(self):
        def handler(request):
            import time
            time.sleep(0.1)
            return {"ready": True}

        with FakeServer(handler) as fake, bridge.RpcClient(fake.path, timeout=0.02) as client:
            with self.assertRaisesRegex(bridge.BridgeError, "call service.ping timed out"):
                client.call("service.ping")

    def test_rpc_connection_remains_usable_after_read_timeout(self):
        def handler(request):
            return {"ready": True}

        with FakeServer(handler) as fake, bridge.RpcClient(fake.path, timeout=0.01) as client:
            with self.assertRaises(socket.timeout):
                client.receive()
            client.sock.settimeout(1)
            self.assertEqual(client.call("service.ping"), {"ready": True})

    def test_rpc_rejects_frame_larger_than_buffer_limit(self):
        def handler(request):
            return "x" * 256

        original_limit = bridge.MAX_RPC_BUFFER_BYTES
        bridge.MAX_RPC_BUFFER_BYTES = 128
        try:
            with FakeServer(handler) as fake, bridge.RpcClient(fake.path) as client:
                with self.assertRaisesRegex(bridge.BridgeError, "frame exceeds 128 bytes"):
                    client.call("service.ping")
                self.assertLessEqual(len(client.buffer), 128)
        finally:
            bridge.MAX_RPC_BUFFER_BYTES = original_limit

    def test_setting_next_sends_bound_target_and_previous_value(self):
        seen = {}

        def handler(request):
            if request["method"] == "settings.list":
                return SETTINGS
            seen.update(request["params"])
            return {**SETTINGS[0], "value": request["params"]["value"]}

        with FakeServer(handler) as fake, bridge.RpcClient(fake.path) as client:
            message = bridge.set_setting(client, "noise-control", None, True)
        self.assertEqual(message, "Noise control: HearThrough")
        self.assertEqual(seen["previous"], "Off")
        self.assertEqual(seen["value"], "HearThrough")
        self.assertEqual(seen["target"], SETTINGS[0]["target"])

    def test_setting_rejects_value_not_returned_by_jabridge(self):
        def handler(request):
            return SETTINGS

        with FakeServer(handler) as fake, bridge.RpcClient(fake.path) as client:
            with self.assertRaisesRegex(bridge.BridgeError, "Invalid value"):
                bridge.set_setting(client, "noise-control", "Calibration", False)

    def test_volume_step_is_bounded_and_uses_returned_target(self):
        seen = {}

        def handler(request):
            if request["method"] == "sound.list":
                changed = json.loads(json.dumps(SOUND))
                changed["nodes"][0]["volume"] = 98
                return changed
            seen.update(request["params"])
            return {}

        with FakeServer(handler) as fake, bridge.RpcClient(fake.path) as client:
            message = bridge.change_volume(client, "output", 5)
        self.assertEqual(message, "Volume: 100%")
        self.assertEqual(seen["percent"], 100)
        self.assertEqual(seen["target"], SOUND["nodes"][0]["target"])

    def test_unavailable_snapshot_has_stable_shape(self):
        value = bridge.unavailable("offline")
        self.assertFalse(value["serviceAvailable"])
        self.assertEqual(value["settings"], [])
        self.assertEqual(value["error"], "offline")

    def test_qml_process_boundary_is_bounded_and_isolated(self):
        service = (ROOT / "Service.qml").read_text()
        self.assertIn('readonly property int oneShotDeadlineMs: 12000', service)
        self.assertIn('readonly property int outputBudgetCharacters: 262144', service)
        self.assertGreaterEqual(service.count('clearEnvironment: true'), 4)
        self.assertIn('return [root.setsidPath, root.pythonPath, "-I", root.bridgePath]', service)
        self.assertNotIn('StdioCollector', service)
        self.assertGreaterEqual(service.count('splitMarker: ""'), 6)
        self.assertIn('[root.killPath, "-KILL", "--", "-" + String(pid)]', service)
        self.assertIn('id: refreshDeadline', service)
        self.assertIn('root.terminateProcessGroup(refreshProcess, refreshKiller)', service)
        self.assertIn('id: actionDeadline', service)
        self.assertIn('root.terminateProcessGroup(actionProcess, actionKiller)', service)


if __name__ == "__main__":
    unittest.main()
