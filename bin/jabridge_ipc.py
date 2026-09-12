#!/usr/bin/env python3
"""Small, dependency-free Jabridge JSON-RPC bridge for the Omarchy plugin."""

from __future__ import annotations

import argparse
import json
import os
import socket
import stat
import sys
import time
from pathlib import Path
from typing import Any

RELEVANT_EVENTS = {
    "device.attached",
    "device.detached",
    "device.battery.update",
    "device.pairing.update",
    "sound.changed",
}


class BridgeError(RuntimeError):
    pass


def socket_path() -> Path:
    configured = os.environ.get("JABRIDGE_SOCKET")
    if configured:
        return Path(configured)
    runtime = os.environ.get("XDG_RUNTIME_DIR")
    if not runtime:
        raise BridgeError("XDG_RUNTIME_DIR is unavailable")
    return Path(runtime) / "jabridge.sock"


def verify_socket(path: Path) -> None:
    try:
        info = path.lstat()
    except FileNotFoundError as exc:
        raise BridgeError("Jabridge is not running") from exc
    if not stat.S_ISSOCK(info.st_mode):
        raise BridgeError(f"Jabridge IPC path is not a socket: {path}")
    if info.st_uid != os.getuid():
        raise BridgeError("Jabridge IPC socket is owned by another user")


class RpcClient:
    def __init__(self, path: Path | None = None, timeout: float = 8.0):
        self.path = path or socket_path()
        verify_socket(self.path)
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(timeout)
        self.sock.connect(str(self.path))
        self.reader = self.sock.makefile("rb")
        self.next_id = 1
        self.notifications: list[dict[str, Any]] = []

    def close(self) -> None:
        try:
            self.reader.close()
        finally:
            self.sock.close()

    def __enter__(self) -> "RpcClient":
        return self

    def __exit__(self, *_: object) -> None:
        self.close()

    def send(self, method: str, params: Any = None) -> int:
        request_id = self.next_id
        self.next_id += 1
        request: dict[str, Any] = {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": method,
        }
        if params is not None:
            request["params"] = params
        self.sock.sendall(json.dumps(request, separators=(",", ":")).encode() + b"\n")
        return request_id

    def receive(self) -> dict[str, Any]:
        line = self.reader.readline()
        if not line:
            raise BridgeError("Jabridge closed the IPC connection")
        try:
            message = json.loads(line)
        except json.JSONDecodeError as exc:
            raise BridgeError("Jabridge returned invalid JSON") from exc
        if not isinstance(message, dict):
            raise BridgeError("Jabridge returned an invalid message")
        return message

    def call(self, method: str, params: Any = None) -> Any:
        request_id = self.send(method, params)
        while True:
            message = self.receive()
            if "id" not in message:
                self.notifications.append(message)
                continue
            if message.get("id") != request_id:
                continue
            error = message.get("error")
            if error:
                detail = error.get("message") if isinstance(error, dict) else str(error)
                raise BridgeError(str(detail or f"Jabridge call {method} failed"))
            return message.get("result")


def selected_headset(devices: list[dict[str, Any]]) -> dict[str, Any] | None:
    headsets = [item for item in devices if not item.get("isDongle")]
    return next((item for item in headsets if item.get("selected")), headsets[0] if headsets else None)


def selected_dongle(devices: list[dict[str, Any]]) -> dict[str, Any] | None:
    dongles = [item for item in devices if item.get("isDongle")]
    return next((item for item in dongles if item.get("selected")), dongles[0] if dongles else None)


def preferred_node(nodes: list[dict[str, Any]], kind: str) -> dict[str, Any] | None:
    matches = [item for item in nodes if item.get("kind") == kind]
    for predicate in (
        lambda item: item.get("default") and item.get("editable"),
        lambda item: item.get("editable"),
        lambda item: True,
    ):
        found = next((item for item in matches if predicate(item)), None)
        if found:
            return found
    return None


def snapshot(client: RpcClient) -> dict[str, Any]:
    devices = client.call("devices.list") or []
    if not isinstance(devices, list):
        raise BridgeError("Jabridge devices.list returned invalid data")
    headset = selected_headset(devices)
    dongle = selected_dongle(devices)

    settings: list[dict[str, Any]] = []
    if headset:
        result = client.call("settings.list", {"device": "headset"}) or []
        if isinstance(result, list):
            settings = [item for item in result if isinstance(item, dict)]

    sound = client.call("sound.list") or {}
    if not isinstance(sound, dict):
        sound = {}
    nodes = sound.get("nodes") if isinstance(sound.get("nodes"), list) else []
    output = preferred_node(nodes, "output")
    microphone = preferred_node(nodes, "microphone")
    battery = headset.get("battery") if headset and isinstance(headset.get("battery"), dict) else None

    return {
        "serviceAvailable": True,
        "connected": headset is not None,
        "device": headset,
        "dongle": dongle,
        "battery": battery,
        "settings": settings,
        "soundAvailable": sound.get("available") is True,
        "inCall": sound.get("inCall") is True,
        "output": output,
        "microphone": microphone,
        "error": "",
    }


def unavailable(message: str) -> dict[str, Any]:
    return {
        "serviceAvailable": False,
        "connected": False,
        "device": None,
        "dongle": None,
        "battery": None,
        "settings": [],
        "soundAvailable": False,
        "inCall": False,
        "output": None,
        "microphone": None,
        "error": message,
    }


def emit(value: dict[str, Any]) -> None:
    print(json.dumps(value, separators=(",", ":")), flush=True)


def watch() -> int:
    last_error = ""
    while True:
        try:
            with RpcClient(timeout=16.0) as client:
                client.call("subscribe")
                emit(snapshot(client))
                last_error = ""
                next_ping = time.monotonic() + 12
                while True:
                    timeout = max(0.1, next_ping - time.monotonic())
                    client.sock.settimeout(timeout)
                    try:
                        message = client.receive()
                    except socket.timeout:
                        client.call("service.ping")
                        next_ping = time.monotonic() + 12
                        continue
                    method = message.get("method")
                    if method in RELEVANT_EVENTS:
                        emit(snapshot(client))
                        next_ping = time.monotonic() + 12
        except (BridgeError, OSError) as exc:
            detail = str(exc) or "Jabridge IPC unavailable"
            if detail != last_error:
                emit(unavailable(detail))
                last_error = detail
            time.sleep(2)


def get_settings(client: RpcClient) -> list[dict[str, Any]]:
    result = client.call("settings.list", {"device": "headset"}) or []
    if not isinstance(result, list):
        raise BridgeError("Jabridge settings.list returned invalid data")
    return [item for item in result if isinstance(item, dict)]


def find_setting(client: RpcClient, key: str) -> dict[str, Any]:
    setting = next((item for item in get_settings(client) if item.get("key") == key), None)
    if not setting:
        raise BridgeError(f"Setting is unavailable: {key}")
    if setting.get("editable") is not True:
        raise BridgeError(f"Setting is read-only: {key}")
    return setting


def set_setting(client: RpcClient, key: str, value: str | None, advance: bool) -> str:
    setting = find_setting(client, key)
    choices = setting.get("choices") if isinstance(setting.get("choices"), list) else []
    if advance:
        if len(choices) < 2:
            raise BridgeError(f"Setting has no selectable choices: {key}")
        try:
            index = choices.index(setting.get("value"))
        except ValueError:
            index = -1
        value = str(choices[(index + 1) % len(choices)])
    elif value not in choices:
        raise BridgeError(f"Invalid value for {key}")
    params = {
        "device": "headset",
        "key": key,
        "value": value,
        "previous": setting.get("value"),
        "target": setting.get("target"),
    }
    result = client.call("settings.set", params)
    shown = result.get("value") if isinstance(result, dict) else value
    return f"{setting.get('label') or key}: {shown}"


def sound_state(client: RpcClient) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    sound = client.call("sound.list") or {}
    if not isinstance(sound, dict) or sound.get("available") is not True:
        raise BridgeError(str(sound.get("error") or "Jabra sound controls are unavailable"))
    nodes = sound.get("nodes") if isinstance(sound.get("nodes"), list) else []
    return sound, nodes


def sound_node(client: RpcClient, kind: str) -> dict[str, Any]:
    _, nodes = sound_state(client)
    node = preferred_node(nodes, kind)
    if not node or node.get("editable") is not True or not isinstance(node.get("target"), dict):
        raise BridgeError(f"Editable Jabra {kind} is unavailable")
    return node


def change_volume(client: RpcClient, kind: str, delta: int) -> str:
    node = sound_node(client, kind)
    current = node.get("volume")
    if not isinstance(current, int):
        raise BridgeError(f"Jabra {kind} volume is unavailable")
    percent = max(0, min(100, current + delta))
    client.call("sound.volume", {"target": node["target"], "percent": percent})
    return f"{'Microphone' if kind == 'microphone' else 'Volume'}: {percent}%"


def toggle_mute(client: RpcClient, kind: str) -> str:
    node = sound_node(client, kind)
    result = client.call("sound.mute", {"target": node["target"], "mode": "toggle"})
    muted = result.get("muted") if isinstance(result, dict) else not bool(node.get("muted"))
    return f"{'Microphone' if kind == 'microphone' else 'Output'} {'muted' if muted else 'unmuted'}"


def change_mode(client: RpcClient, mode: str) -> str:
    node = sound_node(client, "output")
    modes = node.get("modes") if isinstance(node.get("modes"), list) else []
    if mode not in modes:
        raise BridgeError(f"Audio mode is unavailable: {mode}")
    client.call("sound.mode", {"target": node["target"], "mode": mode})
    return f"Audio mode: {mode.title()}"


def action(args: argparse.Namespace) -> int:
    try:
        with RpcClient() as client:
            if args.command == "status":
                emit(snapshot(client))
                return 0
            if args.command == "setting-next":
                message = set_setting(client, args.key, None, True)
            elif args.command == "setting":
                message = set_setting(client, args.key, args.value, False)
            elif args.command == "volume-step":
                message = change_volume(client, args.kind, args.delta)
            elif args.command == "mute-toggle":
                message = toggle_mute(client, args.kind)
            elif args.command == "mode":
                message = change_mode(client, args.mode)
            else:
                raise BridgeError("Unknown command")
        emit({"ok": True, "message": message})
        return 0
    except (BridgeError, OSError) as exc:
        emit({"ok": False, "message": str(exc) or "Jabridge IPC action failed"})
        return 1


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description="Jabridge IPC bridge for Omarchy")
    sub = result.add_subparsers(dest="command", required=True)
    sub.add_parser("status")
    sub.add_parser("watch")
    setting = sub.add_parser("setting")
    setting.add_argument("key")
    setting.add_argument("value")
    setting_next = sub.add_parser("setting-next")
    setting_next.add_argument("key")
    volume = sub.add_parser("volume-step")
    volume.add_argument("kind", choices=("output", "microphone"))
    volume.add_argument("delta", type=int)
    mute = sub.add_parser("mute-toggle")
    mute.add_argument("kind", choices=("output", "microphone"))
    mode = sub.add_parser("mode")
    mode.add_argument("mode", choices=("music", "calls"))
    return result


def main() -> int:
    args = parser().parse_args()
    if args.command == "watch":
        return watch()
    return action(args)


if __name__ == "__main__":
    raise SystemExit(main())
