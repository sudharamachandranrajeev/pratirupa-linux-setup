import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire
import qs.Commons
import qs.Ui

// Dual headphones toggle: makes the combined Bluetooth sink (a PipeWire
// combine-stream that mirrors to every bluez_output) the default output, and
// switches back to the previous single output when turned off.
BarWidget {
  id: root
  moduleName: "pratirupa.dual-headphones"

  readonly property string combinedName: setting("sink", "bt_combined")
  readonly property var nodes: Pipewire.nodes ? Pipewire.nodes.values : []
  readonly property var sink: Pipewire.defaultAudioSink

  readonly property var sinks: {
    var list = []
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i]
      if (n && n.isSink && !n.isStream) list.push(n)
    }
    return list
  }

  readonly property var combined: findSink(combinedName)
  readonly property var headphones: sinks.filter(function(n) { return String(n.name).indexOf("bluez_output.") === 0 })
  readonly property bool enabled: sink !== null && combined !== null && sink.name === combinedName

  // Remembered across plugin hot-reloads so "off" returns to what was playing before.
  PersistentProperties {
    id: memory
    reloadableId: "pratirupa.dual-headphones"
    property string lastSingle: ""
  }

  function rememberSink() {
    if (sink && sink.name && sink.name !== combinedName) memory.lastSingle = String(sink.name)
  }

  onSinkChanged: rememberSink()
  Component.onCompleted: rememberSink()

  function findSink(name) {
    for (var i = 0; i < sinks.length; i++) if (String(sinks[i].name) === name) return sinks[i]
    return null
  }

  function label(node) {
    return node ? String(node.description || node.nickname || node.name) : ""
  }

  // Where "off" goes: the output used before, else a single headphone, else the laptop speaker.
  function fallbackSink() {
    var previous = memory.lastSingle ? findSink(memory.lastSingle) : null
    if (previous) return previous
    if (headphones.length > 0) return headphones[0]
    for (var i = 0; i < sinks.length; i++) if (String(sinks[i].name).indexOf("alsa_output.") === 0) return sinks[i]
    for (var j = 0; j < sinks.length; j++) if (sinks[j] !== combined) return sinks[j]
    return null
  }

  function setDefault(node) {
    if (!node) return
    Pipewire.preferredDefaultAudioSink = node
    Quickshell.execDetached(["omarchy-audio-output-set-default", String(node.id), String(node.name)])
  }

  function toggle() {
    if (enabled) setDefault(fallbackSink())
    else if (headphones.length > 0) setDefault(combined)
  }

  readonly property string tooltip: {
    var names = headphones.map(label).join(" + ")
    if (enabled) {
      if (headphones.length === 0) return "Dual headphones on, but no headphones are connected\nClick to switch to " + label(fallbackSink())
      if (headphones.length === 1) return "Dual headphones on: only " + names + " connected\nClick to switch to " + label(fallbackSink())
      return "Dual headphones on: " + names + "\nClick to switch to " + label(fallbackSink())
    }
    if (headphones.length === 1) return "Dual headphones off: only " + names + " connected\nClick to play on it through the combined output"
    return "Dual headphones off\nClick to play on " + names
  }

  // omarchy-shell pratirupa.dual-headphones toggle   (bindable to a key)
  IpcHandler {
    target: "pratirupa.dual-headphones"
    function toggle(): void { root.toggle() }
    function status(): string { return root.enabled ? "on" : "off" }
  }

  visible: combined !== null && (enabled || headphones.length > 0)
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰋋"
    useActiveColor: false
    dimmed: !root.enabled
    tooltipText: root.tooltip
    iconComponent: Component {
      Item {
        // Two overlapping headphones: the back one smaller and fainter.
        OpticalGlyph {
          x: 0
          y: -Style.space(2)
          width: parent.width * 0.75
          height: parent.height
          text: "󰋋"
          fontFamily: button.fontFamily
          fontSize: button.fontSize * 0.8
          color: button.foreground
          opacity: 0.55
        }
        OpticalGlyph {
          x: parent.width * 0.25
          y: Style.space(2)
          width: parent.width * 0.75
          height: parent.height
          text: "󰋋"
          fontFamily: button.fontFamily
          fontSize: button.fontSize * 0.85
          color: button.foreground
        }
      }
    }
    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.bar.run("omarchy-shell shell toggle omarchy.audio")
      else root.toggle()
    }
  }
}
