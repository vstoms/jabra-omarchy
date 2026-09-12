import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string pluginDirectory: Qt.resolvedUrl(".").toString()
    .replace(/^file:\/\//, "").replace(/\/$/, "")
  readonly property string bridgePath: root.pluginDirectory + "/bin/jabridge_ipc.py"
  readonly property string pythonPath: "/usr/bin/python3"
  readonly property string setsidPath: "/usr/bin/setsid"
  readonly property string killPath: "/usr/bin/kill"
  readonly property int outputBudgetCharacters: 262144
  readonly property int oneShotDeadlineMs: 12000
  readonly property var bridgeEnvironment: ({
    "XDG_RUNTIME_DIR": Quickshell.env("XDG_RUNTIME_DIR"),
    "LANG": "C.UTF-8"
  })

  property bool initialized: false
  property bool serviceAvailable: false
  property bool connected: false
  property var device: null
  property var dongle: null
  property var battery: null
  property var settings: []
  property bool soundAvailable: false
  property bool inCall: false
  property var output: null
  property var microphone: null
  property string backendError: ""
  property string actionMessage: ""
  property int revision: 0

  property string watcherStdoutBuffer: ""
  property string watcherStderrText: ""
  property int watcherStderrCharacters: 0
  property bool watcherBlocked: false

  property string refreshStdoutText: ""
  property string refreshStderrText: ""
  property int refreshOutputCharacters: 0
  property bool refreshAborted: false

  property string actionStdoutText: ""
  property string actionStderrText: ""
  property int actionOutputCharacters: 0
  property bool actionAborted: false

  readonly property bool actionBusy: actionProcess.running
  readonly property string deviceName: device && device.name ? String(device.name) : "Jabra"
  readonly property string connection: device && device.connection ? String(device.connection) : ""
  readonly property string firmware: device && device.firmware ? String(device.firmware) : ""
  readonly property string dongleFirmware: dongle && dongle.firmware ? String(dongle.firmware) : ""
  readonly property bool batteryKnown: battery && Number(battery.level) >= 0
  readonly property int batteryLevel: batteryKnown ? Number(battery.level) : -1
  readonly property bool charging: battery && battery.charging === true
  readonly property string audioMode: output && output.audioMode ? String(output.audioMode) : ""
  readonly property bool outputEditable: output && output.editable === true
  readonly property bool microphoneEditable: microphone && microphone.editable === true

  function bridgeCommand(arguments) {
    // setsid makes the child the leader of a dedicated process group. Every
    // QML process below also clears its inherited environment.
    return [root.setsidPath, root.pythonPath, "-I", root.bridgePath].concat(arguments)
  }

  function terminateProcessGroup(process, killer) {
    if (!process.running) return
    var pid = Number(process.processId)
    if (isFinite(pid) && pid > 1 && !killer.running) {
      killer.command = [root.killPath, "-KILL", "--", "-" + String(pid)]
      killer.running = true
    } else {
      process.signal(9)
    }
  }

  function applySnapshot(raw) {
    try {
      var data = JSON.parse(String(raw || ""))
      if (!data || typeof data !== "object") throw new Error("expected an object")
      root.serviceAvailable = data.serviceAvailable === true
      root.connected = data.connected === true
      root.device = data.device || null
      root.dongle = data.dongle || null
      root.battery = data.battery || null
      root.settings = Array.isArray(data.settings) ? data.settings : []
      root.soundAvailable = data.soundAvailable === true
      root.inCall = data.inCall === true
      root.output = data.output || null
      root.microphone = data.microphone || null
      root.backendError = String(data.error || "")
      root.initialized = true
      root.revision++
    } catch (error) {
      root.backendError = "The Jabridge bridge returned invalid status data."
      console.warn("jabra-omarchy: cannot parse status", String(error))
    }
  }

  function consumeWatcherStdout(chunk) {
    var text = String(chunk || "")
    if (root.watcherStdoutBuffer.length + text.length > root.outputBudgetCharacters) {
      root.watcherBlocked = true
      root.backendError = "Jabridge watcher exceeded its output limit."
      root.terminateProcessGroup(watcher, watcherKiller)
      return
    }
    root.watcherStdoutBuffer += text
    var newline = root.watcherStdoutBuffer.indexOf("\n")
    while (newline >= 0) {
      var line = root.watcherStdoutBuffer.slice(0, newline)
      root.watcherStdoutBuffer = root.watcherStdoutBuffer.slice(newline + 1)
      if (line.length > 0) root.applySnapshot(line)
      newline = root.watcherStdoutBuffer.indexOf("\n")
    }
  }

  function consumeWatcherStderr(chunk) {
    var text = String(chunk || "")
    root.watcherStderrCharacters += text.length
    if (root.watcherStderrCharacters > root.outputBudgetCharacters) {
      root.watcherBlocked = true
      root.backendError = "Jabridge watcher exceeded its output limit."
      root.terminateProcessGroup(watcher, watcherKiller)
      return
    }
    root.watcherStderrText += text
  }

  function consumeRefreshOutput(chunk, stderr) {
    var text = String(chunk || "")
    root.refreshOutputCharacters += text.length
    if (root.refreshOutputCharacters > root.outputBudgetCharacters) {
      root.refreshAborted = true
      root.backendError = "Jabridge refresh exceeded its output limit."
      root.terminateProcessGroup(refreshProcess, refreshKiller)
      return
    }
    if (stderr) root.refreshStderrText += text
    else root.refreshStdoutText += text
  }

  function consumeActionOutput(chunk, stderr) {
    var text = String(chunk || "")
    root.actionOutputCharacters += text.length
    if (root.actionOutputCharacters > root.outputBudgetCharacters) {
      root.actionAborted = true
      root.actionMessage = "Jabridge action exceeded its output limit."
      root.terminateProcessGroup(actionProcess, actionKiller)
      return
    }
    if (stderr) root.actionStderrText += text
    else root.actionStdoutText += text
  }

  function runAction(arguments) {
    if (root.actionBusy || !Array.isArray(arguments) || arguments.length === 0) return
    root.actionMessage = ""
    root.actionAborted = false
    actionProcess.command = root.bridgeCommand(arguments)
    actionProcess.running = true
    actionDeadline.restart()
  }

  function refresh() {
    if (!refreshProcess.running) {
      root.refreshAborted = false
      refreshProcess.command = root.bridgeCommand(["status"])
      refreshProcess.running = true
      refreshDeadline.restart()
    }
  }

  function cycleSetting(key) { runAction(["setting-next", String(key)]) }
  function setSetting(key, value) { runAction(["setting", String(key), String(value)]) }
  function adjustVolume(kind, delta) { runAction(["volume-step", String(kind), String(delta)]) }
  function toggleMute(kind) { runAction(["mute-toggle", String(kind)]) }
  function selectAudioMode(mode) { runAction(["mode", String(mode)]) }

  Process {
    id: watcher
    command: root.bridgeCommand(["watch"])
    clearEnvironment: true
    environment: root.bridgeEnvironment
    running: true
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(chunk) { root.consumeWatcherStdout(chunk) }
    }
    stderr: SplitParser {
      splitMarker: ""
      onRead: function(chunk) { root.consumeWatcherStderr(chunk) }
    }
    onStarted: {
      root.watcherStdoutBuffer = ""
      root.watcherStderrText = ""
      root.watcherStderrCharacters = 0
    }
    onExited: function(exitCode) {
      if (exitCode !== 0 && root.watcherStderrText && !root.watcherBlocked)
        root.backendError = root.watcherStderrText.trim()
      if (!root.watcherBlocked) watcherRestart.restart()
    }
  }

  Timer {
    id: watcherRestart
    interval: 2000
    repeat: false
    onTriggered: if (!root.watcherBlocked) watcher.running = true
  }

  Process {
    id: refreshProcess
    command: []
    clearEnvironment: true
    environment: root.bridgeEnvironment
    running: false
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(chunk) { root.consumeRefreshOutput(chunk, false) }
    }
    stderr: SplitParser {
      splitMarker: ""
      onRead: function(chunk) { root.consumeRefreshOutput(chunk, true) }
    }
    onStarted: {
      root.refreshStdoutText = ""
      root.refreshStderrText = ""
      root.refreshOutputCharacters = 0
    }
    onExited: function(exitCode) {
      refreshDeadline.stop()
      if (root.refreshAborted) {
        root.refreshAborted = false
        return
      }
      if (exitCode === 0) root.applySnapshot(root.refreshStdoutText)
      else root.backendError = String(root.refreshStderrText || "Unable to contact Jabridge").trim()
    }
  }

  Timer {
    id: refreshDeadline
    interval: root.oneShotDeadlineMs
    repeat: false
    onTriggered: {
      if (!refreshProcess.running) return
      root.refreshAborted = true
      root.backendError = "Jabridge refresh timed out."
      root.terminateProcessGroup(refreshProcess, refreshKiller)
    }
  }

  Process {
    id: actionProcess
    command: []
    clearEnvironment: true
    environment: root.bridgeEnvironment
    running: false
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(chunk) { root.consumeActionOutput(chunk, false) }
    }
    stderr: SplitParser {
      splitMarker: ""
      onRead: function(chunk) { root.consumeActionOutput(chunk, true) }
    }
    onStarted: {
      root.actionStdoutText = ""
      root.actionStderrText = ""
      root.actionOutputCharacters = 0
    }
    onExited: function(exitCode) {
      actionDeadline.stop()
      if (root.actionAborted) {
        root.actionAborted = false
        actionMessageTimer.restart()
        return
      }
      var detail = String(root.actionStdoutText || root.actionStderrText || "").trim()
      try {
        var result = JSON.parse(detail)
        root.actionMessage = String(result.message || (exitCode === 0 ? "Done" : "Action failed"))
      } catch (error) {
        root.actionMessage = detail || (exitCode === 0 ? "Done" : "Action failed")
      }
      actionMessageTimer.restart()
      refreshAfterAction.restart()
    }
  }

  Timer {
    id: actionDeadline
    interval: root.oneShotDeadlineMs
    repeat: false
    onTriggered: {
      if (!actionProcess.running) return
      root.actionAborted = true
      root.actionMessage = "Jabridge action timed out."
      root.terminateProcessGroup(actionProcess, actionKiller)
    }
  }

  component GroupKiller: Process {
    clearEnvironment: true
    environment: ({ "LANG": "C.UTF-8" })
    command: []
    running: false
  }

  GroupKiller {
    id: watcherKiller
    onExited: if (watcher.running) watcher.signal(9)
  }
  GroupKiller {
    id: refreshKiller
    onExited: if (refreshProcess.running) refreshProcess.signal(9)
  }
  GroupKiller {
    id: actionKiller
    onExited: if (actionProcess.running) actionProcess.signal(9)
  }

  Timer {
    id: refreshAfterAction
    interval: 500
    repeat: false
    onTriggered: root.refresh()
  }

  Timer {
    id: actionMessageTimer
    interval: 4000
    repeat: false
    onTriggered: root.actionMessage = ""
  }
}
