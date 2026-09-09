import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

import qs.Commons
import qs.Ui

import "MdnsLogic.js" as Mdns

Panel {
  id: root
  moduleName: "leo.mdns"
  ipcTarget: "leo.mdns"

  // Without these, the loader's "shell" in item check skips injection and
  // root.bar.shell.serviceFor() returns null — the panel stays empty.
  property var shell: null
  property var manifest: null
  property var pluginRegistry: null
  property var barWidgetRegistry: null

  // Bar slot collapses to width=0 if the panel (the activeItem) doesn't
  // forward the BarIconButton's intrinsic size — same trap omarchy.network
  // hit before this was added.
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property var mdnsService: root.bar && root.bar.shell ? root.bar.shell.serviceFor("leo.mdns") : null
  readonly property var devicesObj: mdnsService && mdnsService.devices ? mdnsService.devices : ({})
  readonly property int deviceCount: {
    var n = 0
    for (var k in devicesObj) n++
    return n
  }

  readonly property var rows: {
    var list = []
    for (var k in devicesObj) {
      var d = devicesObj[k]
      list.push({
        key: k,
        hostname: d.hostname || "",
        ip: d.ip || "",
        mac: d.mac || "",
        firstSeen: d.firstSeen || 0,
        lastSeen: d.lastSeen || 0,
        services: d.services || []
      })
    }
    list.sort(function(a, b) {
      var ah = (a.hostname || "").toLowerCase()
      var bh = (b.hostname || "").toLowerCase()
      if (ah < bh) return -1
      if (ah > bh) return 1
      return 0
    })
    return list
  }

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property color surface: Color.popups.background
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  function formatRelative(ts) {
    if (!ts) return "—"
    var diff = Date.now() - ts
    if (diff < 0) return "now"
    var sec = Math.floor(diff / 1000)
    if (sec < 60) return sec + "s ago"
    var min = Math.floor(sec / 60)
    if (min < 60) return min + "m ago"
    var hr = Math.floor(min / 60)
    if (hr < 24) return hr + "h ago"
    var day = Math.floor(hr / 24)
    return day + "d ago"
  }

  function clearAll() {
    if (mdnsService && typeof mdnsService.clearDevices === "function") {
      mdnsService.clearDevices()
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰐷"
    tooltipText: root.deviceCount === 1
      ? "1 device on the network"
      : root.deviceCount + " devices on the network"

    onPressed: function(b) {
      if (root.opened) root.close()
      else root.open()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    contentWidth: panel.fittedContentWidth(Style.space(520))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)
    padding: Style.space(16)
    centerOnBar: true

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      ColumnLayout {
        id: column
        anchors.fill: parent
        spacing: Style.space(12)

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)

          Text {
            text: "󰐷"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
            Layout.alignment: Qt.AlignVCenter
          }

          ColumnLayout {
            spacing: 0
            Layout.alignment: Qt.AlignVCenter
            Layout.fillWidth: true

            Text {
              text: "Devices on the network"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }
            Text {
              text: root.deviceCount === 1
                ? "1 discovered via mDNS"
                : root.deviceCount + " discovered via mDNS"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Button {
            id: clearBtn
            text: "Clear"
            tooltipText: "Clear the history of seen devices"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.clearAll()
          }
        }

        Rectangle {
          Layout.fillWidth: true
          height: Style.space(28)
          color: Qt.darker(root.surface, 1.08)
          radius: Style.cornerRadius

          RowLayout {
            anchors.fill: parent
            anchors.leftMargin: Style.space(12)
            anchors.rightMargin: Style.space(12)
            spacing: Style.space(8)

            Text {
              text: "Hostname"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              Layout.preferredWidth: Style.space(140)
            }
            Text {
              text: "IP"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              Layout.preferredWidth: Style.space(110)
            }
            Text {
              text: "MAC"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              Layout.preferredWidth: Style.space(140)
            }
            Text {
              text: "Services"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              Layout.preferredWidth: Style.space(90)
            }
            Text {
              text: "Seen"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              Layout.fillWidth: true
              horizontalAlignment: Text.AlignRight
            }
          }
        }

        Rectangle {
          Layout.fillWidth: true
          Layout.preferredHeight: Math.min(Style.space(360), Style.space(40) + root.rows.length * Style.space(32))
          color: root.surface
          radius: Style.cornerRadius
          border.color: Qt.darker(root.surface, 1.3)
          border.width: 1

          ListView {
            id: list
            anchors.fill: parent
            anchors.margins: Style.space(4)
            clip: true
            model: root.rows
            spacing: 2
            boundsBehavior: Flickable.StopAtBounds

            delegate: Rectangle {
              width: list.width
              height: Style.space(32)
              color: ListView.isCurrentItem
                ? Style.selectedFillFor(root.foreground, Color.accent)
                : (index % 2 === 0 ? "transparent" : Qt.darker(root.surface, 1.03))
              radius: Style.cornerRadius / 2

              RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Style.space(8)
                anchors.rightMargin: Style.space(12)
                spacing: Style.space(8)

                Text {
                  text: modelData.hostname || "(unnamed)"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                  elide: Text.ElideRight
                  Layout.preferredWidth: Style.space(140)
                }
                Text {
                  text: modelData.ip
                  color: root.foreground
                  font.family: "monospace"
                  font.pixelSize: Style.font.bodySmall
                  Layout.preferredWidth: Style.space(110)
                }
                Text {
                  text: modelData.mac || "—"
                  color: modelData.mac ? root.foreground : root.dim
                  font.family: "monospace"
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                  Layout.preferredWidth: Style.space(140)
                }
                Text {
                  text: modelData.services.length > 0
                    ? modelData.services.length + " svc."
                    : "—"
                  color: modelData.services.length > 0 ? root.foreground : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  Layout.preferredWidth: Style.space(90)
                }
                Text {
                  text: root.formatRelative(modelData.lastSeen)
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  Layout.fillWidth: true
                  horizontalAlignment: Text.AlignRight
                }
              }
            }

            Text {
              anchors.centerIn: parent
              visible: root.rows.length === 0
              text: "No devices seen yet.\nAvahi is listening on the network."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              horizontalAlignment: Text.AlignHCenter
            }
          }
        }

        Text {
          text: "Notifications appear when a new device announces itself on the network. " +
                "The list updates automatically."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
          Layout.fillWidth: true
        }
      }
    }
  }
}