import QtQuick

Item {
  id: root

  property real iconSize: 22
  property color color: "white"

  implicitWidth: iconSize
  implicitHeight: iconSize
  width: iconSize
  height: iconSize

  Canvas {
    id: canvas
    anchors.fill: parent

    onPaint: {
      var context = getContext("2d")
      var scale = width / 24
      context.reset()
      context.strokeStyle = String(root.color)
      context.fillStyle = String(root.color)
      context.lineWidth = 2.1 * scale
      context.lineCap = "round"
      context.beginPath()
      context.arc(12 * scale, 11 * scale, 7.2 * scale, Math.PI, 2 * Math.PI)
      context.stroke()
      context.fillRect(3.5 * scale, 10 * scale, 4.1 * scale, 8.3 * scale)
      context.fillRect(16.4 * scale, 10 * scale, 4.1 * scale, 8.3 * scale)
      context.beginPath()
      context.moveTo(18.5 * scale, 18 * scale)
      context.quadraticCurveTo(18.5 * scale, 21 * scale, 15 * scale, 21 * scale)
      context.stroke()
    }

    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()
  }

  onColorChanged: canvas.requestPaint()
}
