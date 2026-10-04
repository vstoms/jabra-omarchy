import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

Panel {
  id: root

  moduleName: "io.github.vstoms.jabra-omarchy"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null

  readonly property var jabraService: bar && bar.shell
    ? bar.shell.serviceFor(root.moduleName) : null
  readonly property color foreground: bar ? bar.barForeground : Color.foreground
  readonly property color dim: Qt.darker(root.foreground, 1.5)
  readonly property color healthy: "#59d98e"
  readonly property color warning: "#f0b45a"
  readonly property color urgent: "#ef5f6b"
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool connected: jabraService ? jabraService.connected : false
  readonly property bool busy: jabraService ? jabraService.actionBusy : false
  readonly property bool showDeviceSettings: hostWidget ? hostWidget.showDeviceSettings : true

  function open() {
    if (root.jabraService) root.jabraService.refresh()
    root.controller.show()
  }
  function close() { root.controller.hide() }
  function toggle() { if (root.opened) root.close(); else root.open() }
  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.hostWidget || root, direction)
    return false
  }
  function batteryText() {
    if (!root.jabraService || !root.jabraService.batteryKnown) return "—"
    return root.jabraService.batteryLevel + "%" + (root.jabraService.charging ? " · charging" : "")
  }
  function listContains(values, wanted) {
    if (!values || values.length === undefined) return false
    for (var i = 0; i < values.length; i++)
      if (String(values[i]) === String(wanted)) return true
    return false
  }
  function settingChoices(setting) {
    if (!setting || !setting.choices || setting.choices.length === undefined) return []
    return setting.choices
  }
  readonly property var soundModes: [
    { value: "ANC", button: "ANC", name: "Active Noise Cancellation" },
    { value: "HearThrough", button: "HEARTHROUGH", name: "HearThrough" },
    { value: "Off", button: "OFF", name: "Off" }
  ]
  readonly property var soundMode: jabraService ? jabraService.soundMode : null
  readonly property bool soundModeEditable: root.soundMode !== null && root.soundMode.editable === true
  function soundModeName(value) {
    for (var i = 0; i < root.soundModes.length; i++)
      if (root.soundModes[i].value === String(value)) return root.soundModes[i].name
    return value === undefined || value === null ? "—" : String(value)
  }
  function hasMode(mode) {
    return root.jabraService && root.jabraService.output
      ? root.listContains(root.jabraService.output.modes, mode) : false
  }

  component DetailRow: Item {
    property string label: ""
    property string value: ""
    width: parent ? parent.width : 0
    implicitHeight: Math.max(detailLabel.implicitHeight, detailValue.implicitHeight)

    Text {
      id: detailLabel
      text: parent.label
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
    }
    Text {
      id: detailValue
      text: parent.value
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      elide: Text.ElideRight
      width: parent.width * 0.62
      horizontalAlignment: Text.AlignRight
    }
  }

  component ActionButton: Button {
    bordered: true
    foreground: root.foreground
    fontFamily: root.fontFamily
    fontSize: Style.font.bodySmall
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        if (!root.jabraService) return
        if (text === "r" || text === "R") root.jabraService.refresh()
        else if (text === "m" || text === "M") root.jabraService.selectAudioMode("music")
        else if (text === "c" || text === "C") root.jabraService.selectAudioMode("calls")
        else if ((text === "n" || text === "N") && root.soundModeEditable && !root.busy)
          root.jabraService.cycleSoundMode()
      }

      Flickable {
        id: panelScroll
        anchors.fill: parent
        contentWidth: content.width
        contentHeight: content.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
          id: content
          width: panelScroll.width
          spacing: Style.space(16)

          PanelHero {
            width: parent.width
            title: root.jabraService ? root.jabraService.deviceName : "Jabra"
            meta: !root.jabraService || !root.jabraService.initialized
              ? "Connecting to Jabridge…"
              : root.jabraService.backendError
                ? root.jabraService.backendError
                : root.connected
                  ? (root.jabraService.connection === "dongle" ? "Connected through Jabra Link" : "Connected by USB")
                  : "No connected Jabra headset"
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: root.connected ? 1.0 : 0.5
            iconComponent: Component {
              JabraIcon { iconSize: Style.font.display; color: root.foreground }
            }
          }

          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: root.connected

            PanelSectionHeader { width: parent.width; text: "DEVICE" }
            DetailRow { label: "Battery"; value: root.batteryText() }
            DetailRow {
              label: "Headset firmware"
              value: root.jabraService ? root.jabraService.firmware || "—" : "—"
            }
            DetailRow {
              visible: root.jabraService && root.jabraService.dongle !== null
              label: "Link firmware"
              value: root.jabraService ? root.jabraService.dongleFirmware || "—" : "—"
            }
            DetailRow {
              label: "Connection"
              value: root.jabraService && root.jabraService.connection === "dongle" ? "Jabra Link" : "USB"
            }
          }

          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: root.connected && root.soundMode !== null

            PanelSectionHeader { width: parent.width; text: "SOUND MODE" }

            Row {
              transform: Translate { x: Style.space(12) }
              spacing: Style.spacing.md
              Repeater {
                model: root.soundModes
                delegate: ActionButton {
                  required property var modelData
                  visible: root.listContains(root.settingChoices(root.soundMode), modelData.value)
                  text: modelData.button
                  selected: root.soundMode !== null && String(root.soundMode.value) === modelData.value
                  enabled: root.soundModeEditable && !root.busy
                  onClicked: {
                    if (!selected) root.jabraService.selectSoundMode(modelData.value)
                  }
                }
              }
            }

            DetailRow {
              label: "Current"
              value: root.soundMode !== null ? root.soundModeName(root.soundMode.value) : "—"
            }
          }

          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: root.jabraService && root.jabraService.soundAvailable && root.jabraService.output !== null

            PanelSectionHeader { width: parent.width; text: "AUDIO" }

            Row {
              transform: Translate { x: Style.space(12) }
              spacing: Style.spacing.md
              ActionButton {
                text: "MUSIC"
                selected: root.jabraService && root.jabraService.audioMode === "music"
                enabled: root.hasMode("music") && !root.busy
                onClicked: root.jabraService.selectAudioMode("music")
              }
              ActionButton {
                text: "CALLS"
                selected: root.jabraService && root.jabraService.audioMode === "calls"
                enabled: root.hasMode("calls") && !root.busy
                onClicked: root.jabraService.selectAudioMode("calls")
              }
              Text {
                text: root.jabraService && root.jabraService.inCall ? "Call active" : ""
                color: root.warning
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Row {
              transform: Translate { x: Style.space(12) }
              spacing: Style.spacing.md
              ActionButton {
                text: "−"
                enabled: root.jabraService && root.jabraService.outputEditable && !root.busy
                onClicked: root.jabraService.adjustVolume("output", -5)
              }
              Text {
                width: Style.space(72)
                text: root.jabraService && root.jabraService.output && root.jabraService.output.volume !== undefined
                  ? Number(root.jabraService.output.volume) + "%" : "—"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                horizontalAlignment: Text.AlignHCenter
                anchors.verticalCenter: parent.verticalCenter
              }
              ActionButton {
                text: "+"
                enabled: root.jabraService && root.jabraService.outputEditable && !root.busy
                onClicked: root.jabraService.adjustVolume("output", 5)
              }
              ActionButton {
                text: root.jabraService && root.jabraService.output && root.jabraService.output.muted ? "UNMUTE" : "MUTE"
                selected: root.jabraService && root.jabraService.output && root.jabraService.output.muted === true
                enabled: root.jabraService && root.jabraService.outputEditable && !root.busy
                onClicked: root.jabraService.toggleMute("output")
              }
            }

            Row {
              transform: Translate { x: Style.space(12) }
              visible: root.jabraService && root.jabraService.microphone !== null
              spacing: Style.spacing.md
              Text {
                width: Style.space(150)
                text: "Microphone " + (root.jabraService && root.jabraService.microphone && root.jabraService.microphone.volume !== undefined
                  ? Number(root.jabraService.microphone.volume) + "%" : "")
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                anchors.verticalCenter: parent.verticalCenter
              }
              ActionButton {
                text: "−"
                enabled: root.jabraService && root.jabraService.microphoneEditable && !root.busy
                onClicked: root.jabraService.adjustVolume("microphone", -5)
              }
              ActionButton {
                text: "+"
                enabled: root.jabraService && root.jabraService.microphoneEditable && !root.busy
                onClicked: root.jabraService.adjustVolume("microphone", 5)
              }
              ActionButton {
                text: root.jabraService && root.jabraService.microphone && root.jabraService.microphone.muted ? "UNMUTE" : "MUTE"
                selected: root.jabraService && root.jabraService.microphone && root.jabraService.microphone.muted === true
                enabled: root.jabraService && root.jabraService.microphoneEditable && !root.busy
                onClicked: root.jabraService.toggleMute("microphone")
              }
            }
          }

          Column {
            id: settingsColumn
            width: parent.width
            spacing: Style.space(9)
            visible: root.connected && root.showDeviceSettings && root.jabraService && root.jabraService.otherSettings.length > 0

            PanelSectionHeader { width: parent.width; text: "HEADSET SETTINGS" }

            Repeater {
              model: root.jabraService ? root.jabraService.otherSettings : []
              delegate: Item {
                required property var modelData
                width: settingsColumn.width
                implicitHeight: Math.max(settingText.implicitHeight, settingDropdown.implicitHeight)

                Column {
                  id: settingText
                  anchors.left: parent.left
                  anchors.right: settingDropdown.left
                  anchors.rightMargin: Style.space(12)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(2)

                  Text {
                    width: parent.width
                    text: String(modelData.label || modelData.key || "Setting")
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    elide: Text.ElideRight
                  }
                  Text {
                    width: parent.width
                    visible: modelData.mayRestart === true || root.settingChoices(modelData).length < 2
                    text: modelData.mayRestart === true ? "May restart the headset" : "Read only"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }

                Dropdown {
                  id: settingDropdown
                  width: Style.space(180)
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  showLabel: false
                  value: String(modelData.value === undefined ? "" : modelData.value)
                  options: root.settingChoices(modelData).length > 0 ? root.settingChoices(modelData) : [value]
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  enabled: modelData.editable === true
                    && root.settingChoices(modelData).length > 1
                    && !root.busy
                  opacity: enabled ? 1.0 : 0.6
                  onChanged: function(nextValue) {
                    root.jabraService.setSetting(String(modelData.key), nextValue)
                  }
                }
              }
            }
          }

          Text {
            width: parent.width
            visible: root.jabraService && (root.jabraService.actionMessage !== "" || root.jabraService.backendError !== "")
            text: root.jabraService ? (root.jabraService.actionMessage || root.jabraService.backendError) : ""
            color: root.jabraService && root.jabraService.backendError ? root.urgent : root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Row {
            spacing: Style.spacing.md
            ActionButton {
              text: "REFRESH"
              enabled: !root.busy
              onClicked: { if (root.jabraService) root.jabraService.refresh() }
            }
            Text {
              text: root.soundModeEditable
                ? "M Music · C Calls · N Sound mode · R Refresh · Tab next panel"
                : "M Music · C Calls · R Refresh · Tab next panel"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              anchors.verticalCenter: parent.verticalCenter
            }
          }
        }
      }
    }
  }
}
