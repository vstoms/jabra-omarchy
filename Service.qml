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

  function bridgeCommand(arguments) {
    return [root.pythonPath, "-I", root.bridgePath].concat(arguments)
  }

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
  property bool refreshTimedOut: false
  property bool actionTimedOut: false
  readonly property int oneShotDeadlineMs: 12000

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

  function runAction(arguments) {
    if (root.actionBusy || !Array.isArray(arguments) || arguments.length === 0) return
    root.actionMessage = ""
    root.actionTimedOut = false
    actionProcess.command = root.bridgeCommand(arguments)
    actionProcess.running = true
    actionDeadline.restart()
  }

  function refresh() {
    if (!refreshProcess.running) {
      root.refreshTimedOut = false
      refreshProcess.command = root.bridgeCommand(["status"])
      refreshProcess.running = true
      refreshDeadline.restart()
    }
  }

  function cycleSetting(key) { runAction(["setting-next", String(key)]) }
  function setSetting(key, value) { runAction(["setting", String(key), String(value)]) }
  function adjustVolume(kind, delta) {
    runAction(["volume-step", String(kind), String(delta)])
  }
  function toggleMute(kind) { runAction(["mute-toggle", String(kind)]) }
  function selectAudioMode(mode) { runAction(["mode", String(mode)]) }

  Process {
    id: watcher
    command: root.bridgeCommand(["watch"])
    running: true
    stdout: SplitParser {
      onRead: function(line) { root.applySnapshot(line) }
    }
    stderr: StdioCollector { id: watcherError; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0 && watcherError.text)
        root.backendError = String(watcherError.text).trim()
      watcherRestart.restart()
    }
  }

  Timer {
    id: watcherRestart
    interval: 2000
    repeat: false
    onTriggered: watcher.running = true
  }

  Process {
    id: refreshProcess
    command: []
    running: false
    stdout: StdioCollector { id: refreshOutput; waitForEnd: true }
    stderr: StdioCollector { id: refreshError; waitForEnd: true }
    onExited: function(exitCode) {
      refreshDeadline.stop()
      if (root.refreshTimedOut) {
        root.refreshTimedOut = false
        return
      }
      if (exitCode === 0) root.applySnapshot(refreshOutput.text)
      else root.backendError = String(refreshError.text || "Unable to contact Jabridge").trim()
    }
  }

  Timer {
    id: refreshDeadline
    interval: root.oneShotDeadlineMs
    repeat: false
    onTriggered: {
      if (!refreshProcess.running) return
      root.refreshTimedOut = true
      root.backendError = "Jabridge refresh timed out."
      refreshProcess.signal(9)
    }
  }

  Process {
    id: actionProcess
    command: []
    running: false
    stdout: StdioCollector { id: actionOutput; waitForEnd: true }
    stderr: StdioCollector { id: actionError; waitForEnd: true }
    onExited: function(exitCode) {
      actionDeadline.stop()
      if (root.actionTimedOut) {
        root.actionTimedOut = false
        actionMessageTimer.restart()
        return
      }
      var detail = String(actionOutput.text || actionError.text || "").trim()
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
      root.actionTimedOut = true
      root.actionMessage = "Jabridge action timed out."
      actionProcess.signal(9)
    }
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
