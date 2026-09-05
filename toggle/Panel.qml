import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar button + menu that switches the whole desktop scheme between
// GNOME-like desktops (avalgott.gnome-like-workspaces) and stock Omarchy
// workspaces. The button lives in the right section, left of omarchy.agents,
// and stays visible in both modes -- it is the only way back.
//
// The engine is toggle.sh in this directory: it flips the state file
// ~/.config/hypr/desktops.enabled, reloads Hyprland (the Lua module gates
// itself on that file) and swaps the bar widgets. This file only renders
// state and fires commands.
Panel {
  id: root
  moduleName: "avalgott.gnome-like-workspaces-toggle"
  manageIpc: false

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string statePath: root.home + "/.config/hypr/desktops.enabled"
  readonly property string toggleScript: root.home
    + "/.config/omarchy/plugins/avalgott.gnome-like-workspaces-toggle/toggle.sh"
  property bool gnomeEnabled: true

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color hoverFill: bar
    ? Style.hoverFillFor(bar.foreground, Color.accent) : "transparent"
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  function parseState(content) {
    root.gnomeEnabled = !/^\s*false\s*$/.test(String(content || ""))
  }

  FileView {
    id: stateView
    path: root.statePath
    preload: true
    watchChanges: true
    printErrors: false
    onLoaded: root.parseState(text())
    onFileChanged: reload()
    onLoadFailed: root.parseState("")   // missing state file = enabled
  }

  // FileView cannot watch a file that does not exist yet; the dir watch
  // catches a state file created after the widget loaded.
  FileView {
    id: stateDirWatch
    path: root.home + "/.config/hypr"
    watchChanges: true
    printErrors: false
    onFileChanged: stateView.reload()
  }

  function runToggle(action) {
    if (!root.bar) return
    root.bar.run(Util.shellQuote(root.toggleScript) + " " + action)
    root.close()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰨇"            // md-monitor_dashboard (U+F0A07)
    dimmed: !root.gnomeEnabled      // WidgetButton.dimmed -> opacity 0.45
    tooltipText: root.gnomeEnabled ? "GNOME-like desktops" : "Omarchy workspaces"
    onPressed: function(b) { root.toggle() }
  }

  PopupCard {
    id: card
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    triggerMode: "click"
    // padding inherits Style.spacing.popupPadding (14), like the bluetooth
    // and audio panels' KeyboardPanels.
    contentWidth: card.fittedContentWidth(Style.space(280))
    contentHeight: card.fittedContentHeight(menuColumn.implicitHeight)

    Column {
      id: menuColumn
      anchors.fill: parent
      spacing: Style.space(14)

      // Hero: toggle glyph · mode title — mirrors the bluetooth panel's
      // hero: display-size icon, title + small-caps status line.
      Item {
        width: parent.width
        implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)

        Text {
          id: heroIcon
          textFormat: Text.PlainText
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          text: "󰨇"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.display
          opacity: root.gnomeEnabled ? 1.0 : 0.5
        }

        Column {
          id: heroLabels
          anchors.left: heroIcon.right
          anchors.leftMargin: Style.space(14)
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(2)

          Text {
            text: "Workspaces"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
            elide: Text.ElideRight
            width: parent.width
          }

          Text {
            textFormat: Text.PlainText
            text: root.gnomeEnabled ? "GNOME-LIKE DESKTOPS" : "OMARCHY WORKSPACES"
            color: Qt.darker(root.foreground, 1.4)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1.2
            elide: Text.ElideRight
            width: parent.width
          }
        }
      }

      PanelSeparator {
        foreground: root.foreground
      }

      ModeRow {
        width: menuColumn.width
        label: "GNOME-like desktops"
        hint: "One keypress switches every monitor"
        checked: root.gnomeEnabled
        onActivated: root.runToggle("enable")
      }

      ModeRow {
        width: menuColumn.width
        label: "Omarchy workspaces"
        hint: "Stock behavior: one monitor at a time"
        checked: !root.gnomeEnabled
        onActivated: root.runToggle("disable")
      }
    }
  }

  component ModeRow: Item {
    id: row
    property string label: ""
    property string hint: ""
    property bool checked: false
    signal activated()

    implicitHeight: rowText.implicitHeight + (row.hint !== "" ? hintText.implicitHeight : 0)
      + Style.space(14)

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: rowHover.hovered ? root.hoverFill : "transparent"
    }

    Column {
      anchors.left: parent.left
      anchors.right: checkText.left
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(1)

      Text {
        id: rowText
        width: parent.width
        text: row.label
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: row.checked
        elide: Text.ElideRight
      }

      Text {
        id: hintText
        visible: row.hint !== ""
        width: parent.width
        text: row.hint
        color: Qt.darker(root.foreground, 1.4)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }

    Text {
      id: checkText
      text: row.checked ? "✓" : ""
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.title
      anchors.right: parent.right
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
    }

    HoverHandler { id: rowHover }

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: {
        if (row.checked) root.close()   // active mode: just dismiss
        else row.activated()
      }
    }
  }
}
