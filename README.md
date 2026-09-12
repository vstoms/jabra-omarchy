# Jabridge for Omarchy

An Omarchy Quattro bar plugin for Jabra headsets managed by
[Jabridge](https://github.com/Watchdog0x/jabridge).

![Jabridge for Omarchy showing a connected Jabra headset](preview.png)

The plugin is an IPC frontend. It never opens USB, HID, or Bluetooth devices itself.
Jabridge remains the single owner of device communication.

## Features

- Connected Jabra headset, connection type, firmware, and battery status.
- Jabra Link firmware information when a dongle is present.
- Output and microphone volume and mute controls through Jabridge/PipeWire.
- Explicit Music and Calls audio modes when Jabridge advertises them.
- Headset settings discovered dynamically from `settings.list`.
- Event-driven updates using Jabridge subscriptions, with reconnect and keepalive handling.

A setting appears only when Jabridge returns it. For example, ANC/HearThrough controls
will appear automatically if a future Jabridge release exposes `noise-control` for the
connected model. This plugin does not invent or bypass unsupported settings.

## Requirements

- Omarchy Quattro 4.0 or newer.
- Python 3.
- Jabridge with its user service installed and running.

Install and start Jabridge first:

```sh
jabridge setup
jabridge service start
jabridge ipc ping
```

## Install the plugin

From GitHub:

```sh
omarchy plugin add https://github.com/vstoms/jabra-omarchy --enable --yes
```

From a local checkout:

```sh
omarchy plugin add "$PWD" --enable --section right
omarchy-shell shell rescanPlugins
```

The bar widget settings can hide it while disconnected, hide the battery percentage,
or hide the headset-settings section.

## Remove the plugin

```sh
omarchy plugin remove io.github.vstoms.jabra-omarchy --yes
```

Removing this frontend does not remove Jabridge, its user service, or its udev rule.
Manage those separately with Jabridge's own setup commands.

## IPC behavior and safety

The bridge connects to `$JABRIDGE_SOCKET`, or `$XDG_RUNTIME_DIR/jabridge.sock` by
default. It requires the socket to be owned by the current user. Automatic processes
use the system interpreter at `/usr/bin/python3` in isolated mode, so inherited `PATH`,
`PYTHONPATH`, and user site packages cannot select or alter the Python runtime. Incoming
newline-delimited JSON-RPC frames are bounded to 1 MiB before parsing.

For changes, the bridge first reads current state and reuses Jabridge's complete opaque
`target`. Headset setting changes also include the current value as `previous`. Values
not returned in the setting's `choices` are rejected. This follows Jabridge's stale-state
and device-replacement protections.

The plugin does not expose firmware installation, device reset, pairing, or arbitrary
JSON-RPC calls.

## Commands

The plugin-local bridge is useful for diagnostics:

```sh
BRIDGE="$HOME/.config/omarchy/plugins/io.github.vstoms.jabra-omarchy/bin/jabridge_ipc.py"
"$BRIDGE" status
"$BRIDGE" watch
"$BRIDGE" volume-step output -5
"$BRIDGE" mute-toggle microphone
"$BRIDGE" mode music
```

## Development

```sh
python -m unittest discover -s tests -v
python -m py_compile bin/jabridge_ipc.py tests/test_bridge.py
omarchy plugin validate .
```

## License

MIT. Jabra and Jabridge are trademarks or project names belonging to their respective
owners. This project is independent and is not endorsed by GN Audio or the Jabridge
project.
