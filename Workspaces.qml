import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "avalgott.gnome-like-workspaces"

  // A desktop spans every monitor. Each monitor owns a block of workspace ids
  // (monitor slot * stride + desktop), so many workspaces map to one button.
  // count/stride are parsed out of the user's settings file, ~/.config/hypr/
  // desktops.lua, so this file never needs per-machine edits. Defaults below
  // match the plugin's defaults.
  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string settingsPath: root.home + "/.config/hypr/desktops.lua"
  property int count: 5
  property int stride: 10

  function parseSettings(content) {
    var text = String(content || "")
    var countMatch = text.match(/(?:^|\n)[ \t]*count[ \t]*=[ \t]*([0-9]+)/)
    var strideMatch = text.match(/(?:^|\n)[ \t]*stride[ \t]*=[ \t]*([0-9]+)/)

    if (text.length > 0 && (!countMatch || !strideMatch)) {
      console.warn("avalgott.gnome-like-workspaces: count/stride not found in " +
        root.settingsPath + " - using defaults (count=5 stride=10)")
    }

    if (countMatch) root.count = parseInt(countMatch[1], 10)
    if (strideMatch) root.stride = parseInt(strideMatch[1], 10)
  }

  FileView {
    id: settingsView
    path: root.settingsPath
    preload: true
    watchChanges: true
    printErrors: false
    onLoaded: root.parseSettings(text())
    onFileChanged: reload()
    onLoadFailed: root.parseSettings("")
  }

  // FileView cannot watch a file that does not exist yet, so watch the
  // directory too: a settings file created after the widget loaded (e.g.
  // install.sh running after a shell start) gets picked up.
  FileView {
    id: settingsDirWatch
    path: root.home + "/.config/hypr"
    watchChanges: true
    printErrors: false
    onFileChanged: settingsView.reload()
  }

  function desktopOf(id) {
    return ((id - 1) % root.stride) + 1
  }

  // Derived from the workspace list rather than hardcoded, so raising the
  // desktop count in the settings file grows the bar with no edit here. The
  // workspace rules are persistent, so every desktop is always present.
  function desktopIds() {
    var ids = []
    var values = Hyprland.workspaces.values

    for (var i = 0; i < values.length; i++) {
      var id = values[i].id
      if (id < 1) continue

      var desktop = root.desktopOf(id)
      if (ids.indexOf(desktop) === -1) ids.push(desktop)
    }

    if (ids.length === 0) ids.push(1)

    ids.sort(function(left, right) { return left - right })
    return ids
  }

  // Lit when any monitor has windows on this desktop, so the laptop bar
  // reflects what is sitting on the external screen too.
  function desktopOccupied(desktop) {
    var values = Hyprland.workspaces.values

    for (var i = 0; i < values.length; i++) {
      var workspace = values[i]
      if (workspace.id < 1 || root.desktopOf(workspace.id) !== desktop) continue
      if (workspace.toplevels.values.length > 0) return true
    }

    return false
  }

  function switchDesktop(desktop) {
    if (!root.bar) return
    root.bar.run("hyprctl eval " + Util.shellQuote("Desktops.switch(" + desktop + ")"))
  }

  readonly property real trailingGap: root.vertical ? 0 : Style.spaceReal(1.5)

  implicitWidth: grid.implicitWidth + trailingGap
  implicitHeight: grid.implicitHeight

  GridLayout {
    id: grid
    anchors.fill: parent
    anchors.rightMargin: root.trailingGap
    columns: root.vertical ? 1 : root.desktopIds().length
    columnSpacing: root.vertical ? 0 : Style.space(1)
    rowSpacing: root.vertical ? Style.space(2) : 0

    Repeater {
      model: root.desktopIds()

      WidgetButton {
        required property int modelData

        readonly property bool occupied: root.desktopOccupied(modelData)
        readonly property bool focused: Hyprland.focusedWorkspace !== null
          && Hyprland.focusedWorkspace.id > 0
          && root.desktopOf(Hyprland.focusedWorkspace.id) === modelData

        bar: root.bar
        text: focused ? "󱓻" : (modelData === 10 ? "0" : String(modelData))
        opacity: occupied || focused ? 1 : 0.5
        horizontalMargin: 6
        verticalPadding: 6
        fixedWidth: root.vertical ? root.barSize : Style.space(20)
        fixedHeight: root.barSize
        onPressed: function() { root.switchDesktop(modelData) }
      }
    }
  }
}
