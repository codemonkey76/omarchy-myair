import QtQuick
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model

Panel {
  id: root
  moduleName: "io.github.codemonkey76.myair"
  ipcTarget: "io.github.codemonkey76.myair"
  // manageIpc: false so the IpcHandler below can own the single handler the
  // target allows — the base Panel's covers open/close/toggle but not power.
  manageIpc: false

  // ---- Connection ---------------------------------------------------------
  // Everything addressable lives in this widget's shell.json entry, so a DHCP
  // move (or a second system) is a config edit, not a QML edit.
  readonly property string host: String(setting("host", ""))
  readonly property bool configured: host !== ""
  readonly property int port: parseInt(setting("port", 2025), 10) || 2025
  readonly property string acKey: String(setting("ac", "ac1"))
  readonly property int refreshSeconds: Math.max(5, parseInt(setting("refreshSeconds", 30), 10) || 30)
  readonly property string baseUrl: "http://" + host + ":" + port

  // ---- State --------------------------------------------------------------
  // `ac` is the last *good* reading and is deliberately kept across failures:
  // a dropped poll should leave the last known state on the bar, not blank it.
  property var ac: null
  property bool reachable: false
  property bool everLoaded: false

  // Optimistic overlay — what the user just asked for, held until the tablet
  // reports it back. The unit takes a second or two to reflect a change, so
  // without this every press would visibly snap back before taking effect.
  property var pendingInfo: ({})
  property var pendingZones: ({})

  readonly property var info: ac ? ac.info : null
  readonly property bool isOn: infoValue("state", "off") === "on"
  readonly property string mode: String(infoValue("mode", "cool"))
  readonly property string fan: String(infoValue("fan", "low"))
  readonly property real setTemp: Number(infoValue("setTemp", NaN))
  readonly property int myZone: Number(infoValue("myZone", 0)) || 0
  readonly property string acName: (info && info.name) ? String(info.name) : "MyAir"
  readonly property var zones: buildZones()

  // Vent moves air without a setpoint, so the target is meaningless there.
  readonly property bool targetApplies: isOn && mode !== "vent"

  // One dim for the whole control area when the tablet is out of reach; the
  // readings above it stay at full strength because they are still worth reading.
  readonly property real controlsOpacity: reachable ? 1.0 : 0.5

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  function infoValue(key, fallback) {
    if (pendingInfo[key] !== undefined) return pendingInfo[key]
    if (info && info[key] !== undefined && info[key] !== null) return info[key]
    return fallback
  }

  function buildZones() {
    var list = Model.zoneList(ac)
    for (var i = 0; i < list.length; i++) {
      var p = pendingZones[list[i].key]
      if (!p) continue
      if (p.state !== undefined) list[i].open = (p.state === "open")
      if (p.setTemp !== undefined) list[i].setTemp = p.setTemp
    }
    return list
  }

  function zoneByKey(key) {
    for (var i = 0; i < zones.length; i++)
      if (zones[i].key === key) return zones[i]
    return null
  }

  // ---- Bar presentation ---------------------------------------------------
  readonly property string barIcon: (!reachable || !configured) ? Model.ICON_DOWN
                                  : (!isOn ? Model.ICON_IDLE : Model.modeIcon(mode))
  readonly property string pillText: (reachable && isOn && targetApplies)
    ? barIcon + " " + Model.formatTemp(setTemp)
    : barIcon
  readonly property string tooltipText: configured
    ? Model.tooltip(reachable, isOn, mode, fan, setTemp, zones)
    : "MyAir — set \"host\" in shell.json"

  // ---- Reading ------------------------------------------------------------
  function refresh() {
    if (!configured || getProc.running) return
    getProc.command = ["curl", "-fsS", "--max-time", "5", root.baseUrl + "/getSystemData"]
    getProc.running = true
  }

  Process {
    id: getProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = Model.parseAircon(text, root.acKey)
        // Null means the tablet handed back its stripped mid-write payload.
        // Keep the last good reading rather than showing a panel of dashes.
        if (!parsed) return

        root.ac = parsed
        root.reachable = true
        root.everLoaded = true

        // Only drop the optimistic overlay once nothing is in flight. A
        // reading that left the tablet before our command landed would
        // otherwise briefly undo what the user just pressed.
        if (!root.sending && root.queue.length === 0) {
          root.pendingInfo = ({})
          root.pendingZones = ({})
        }
      }
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) root.reachable = false
    }
  }

  // Poll harder while the panel is open — someone watching the room
  // temperatures wants them live, but the closed bar pill does not.
  Timer {
    interval: (root.opened ? 5 : root.refreshSeconds) * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // ---- Writing ------------------------------------------------------------
  // curl runs one at a time, so commands queue. Each is independent, and the
  // tablet applies them in order.
  property var queue: []
  property bool sending: false
  property string lastError: ""

  function enqueue(payload) {
    var q = queue.slice()
    q.push(JSON.stringify(payload))
    queue = q
    pump()
  }

  function pump() {
    if (sending || queue.length === 0) return
    var next = queue[0]
    queue = queue.slice(1)
    sending = true
    setProc.command = ["curl", "-fsS", "--max-time", "6", "-G",
                       root.baseUrl + "/setAircon", "--data-urlencode", "json=" + next]
    setProc.running = true
  }

  Process {
    id: setProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        // ack:false means the tablet understood the JSON but rejected a value.
        // Surface it instead of leaving a control silently stuck optimistic.
        try {
          var res = JSON.parse(String(text || "").trim())
          root.lastError = (res && res.ack === false) ? String(res.reason || "Rejected") : ""
        } catch (e) {
          root.lastError = ""
        }
      }
    }
    onExited: function(exitCode) {
      root.sending = false
      if (exitCode !== 0) {
        root.reachable = false
        root.lastError = "No response"
      }
      if (root.queue.length > 0) root.pump()
      else settleTimer.restart()
    }
  }

  // Give the unit a beat to actually apply the change before reading back;
  // polling immediately just returns the stripped payload.
  Timer {
    id: settleTimer
    interval: 1500
    onTriggered: root.refresh()
  }

  function sendInfo(patch) {
    var merged = {}
    for (var k in pendingInfo) merged[k] = pendingInfo[k]
    for (var p in patch) merged[p] = patch[p]
    pendingInfo = merged
    lastError = ""

    var payload = {}
    payload[acKey] = { info: patch }
    enqueue(payload)
  }

  function sendZone(key, patch) {
    var merged = {}
    for (var k in pendingZones) merged[k] = pendingZones[k]
    var z = {}
    if (merged[key]) for (var q in merged[key]) z[q] = merged[key][q]
    for (var p in patch) z[p] = patch[p]
    merged[key] = z
    pendingZones = merged
    lastError = ""

    var zonesPatch = {}
    zonesPatch[key] = patch
    var payload = {}
    payload[acKey] = { zones: zonesPatch }
    enqueue(payload)
  }

  // Every command is gated on `reachable`. The panel deliberately keeps the
  // last good readings on screen when the tablet drops off the network (a
  // laptop leaving the house), and those stale readings must not look like
  // live controls — nothing should queue a request that cannot land.
  function togglePower() { if (reachable) sendInfo({ state: isOn ? "off" : "on" }) }
  function setMode(value) { if (reachable && value !== mode) sendInfo({ mode: value }) }
  function setFan(value) { if (reachable && value !== fan) sendInfo({ fan: value }) }
  function toggleZone(key) {
    if (!reachable) return
    var z = zoneByKey(key)
    if (z) sendZone(key, { state: z.open ? "close" : "open" })
  }

  // ---- Setpoints ----------------------------------------------------------
  // Taps land on the overlay immediately but the request is debounced, so
  // holding +/+ /+ is one command at the end rather than one per degree.
  function nudgeTarget(delta) {
    if (!reachable) return
    var base = isNaN(setTemp) ? 24 : setTemp
    var merged = {}
    for (var k in pendingInfo) merged[k] = pendingInfo[k]
    merged.setTemp = Model.clampTemp(base + delta)
    pendingInfo = merged
    targetDebounce.restart()
  }

  Timer {
    id: targetDebounce
    interval: 450
    onTriggered: {
      if (root.pendingInfo.setTemp === undefined) return
      var payload = {}
      payload[root.acKey] = { info: { setTemp: root.pendingInfo.setTemp } }
      root.enqueue(payload)
    }
  }

  property var dirtyZoneTemps: ({})

  function nudgeZone(key, delta) {
    if (!reachable) return
    var z = zoneByKey(key)
    if (!z) return
    var next = Model.clampTemp((isNaN(z.setTemp) ? 24 : z.setTemp) + delta)

    var merged = {}
    for (var k in pendingZones) merged[k] = pendingZones[k]
    var entry = {}
    if (merged[key]) for (var q in merged[key]) entry[q] = merged[key][q]
    entry.setTemp = next
    merged[key] = entry
    pendingZones = merged

    var dirty = {}
    for (var d in dirtyZoneTemps) dirty[d] = dirtyZoneTemps[d]
    dirty[key] = next
    dirtyZoneTemps = dirty
    zoneDebounce.restart()
  }

  Timer {
    id: zoneDebounce
    interval: 450
    onTriggered: {
      var zonesPatch = {}
      var any = false
      for (var k in root.dirtyZoneTemps) {
        zonesPatch[k] = { setTemp: root.dirtyZoneTemps[k] }
        any = true
      }
      root.dirtyZoneTemps = ({})
      if (!any) return

      // The tablet takes several zones in one call, so adjusting two rooms
      // in quick succession costs one request.
      var payload = {}
      payload[root.acKey] = { zones: zonesPatch }
      root.enqueue(payload)
    }
  }

  onOpenedChanged: if (opened) refresh()

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  IpcHandler {
    target: "io.github.codemonkey76.myair"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function power(): void { root.togglePower() }
    function refresh(): void { root.refresh() }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.pillText
    slotSize: Style.bar.statusSlot
    tooltipText: root.opened ? "" : root.tooltipText
    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.refresh()
      else if (b === Qt.RightButton) root.togglePower()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "p" || t === "P") root.togglePower()
        else if (t === "r" || t === "R") root.refresh()
      }

      Column {
        id: column
        anchors.fill: parent
        spacing: Style.space(14)

        // ---------- Hero: mode icon · name · status · power ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, powerSwitch.implicitHeight)

          Text {
            id: heroIcon
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: root.barIcon
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
            opacity: root.isOn && root.reachable ? 1.0 : 0.5
          }

          ToggleSwitch {
            id: powerSwitch
            visible: root.reachable
            checked: root.isOn
            foreground: root.fg
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            onToggled: root.togglePower()

            PanelToolTip {
              visible: powerSwitch.containsMouse
              text: root.isOn ? "Turn off" : "Turn on"
              fontFamily: root.fontFamily
            }
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: parent.right
            anchors.rightMargin: powerSwitch.visible ? powerSwitch.width + Style.space(12) : 0
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: root.acName
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              textFormat: Text.PlainText
              text: (!root.configured ? "Not configured"
                    : root.lastError !== "" ? root.lastError
                    : Model.statusLine(root.reachable, root.isOn, root.mode, root.fan)).toUpperCase()
              color: root.lastError !== "" ? Color.urgent : Qt.darker(root.fg, 1.4)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
              width: parent.width
            }
          }
        }

        // ---------- Nothing to show until the first reading lands ----------
        Text {
          visible: !root.everLoaded
          width: parent.width
          textFormat: Text.PlainText
          text: !root.configured
                ? "Add \"host\": \"<tablet-ip>\" to this widget's entry in ~/.config/omarchy/shell.json"
                : (root.reachable ? "Loading…" : ("No response from " + root.host))
          color: Qt.darker(root.fg, 1.4)
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        PanelSeparator {
          visible: root.everLoaded
          foreground: root.fg
        }

        // ---------- Target setpoint ----------
        Item {
          visible: root.everLoaded
          width: parent.width
          implicitHeight: targetStepper.implicitHeight
          opacity: (root.targetApplies ? 1.0 : 0.4) * root.controlsOpacity

          PanelSectionHeader {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: root.mode === "vent" ? "NO TARGET IN VENT" : "TARGET"
            foreground: root.fg
            fontFamily: root.fontFamily
          }

          TempStepper {
            id: targetStepper
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            value: root.setTemp
            fontSize: Style.font.heading
            live: root.targetApplies
            onNudged: function(delta) { if (root.targetApplies) root.nudgeTarget(delta) }
          }
        }

        // ---------- Mode ----------
        Column {
          visible: root.everLoaded
          width: parent.width
          spacing: Style.space(6)
          opacity: root.controlsOpacity

          PanelSectionHeader {
            text: "MODE"
            foreground: root.fg
            fontFamily: root.fontFamily
          }

          ButtonGroup {
            options: Model.MODES
            value: root.mode
            foreground: root.fg
            background: root.bar ? root.bar.background : Color.background
            fontFamily: root.fontFamily
            focusable: false
            onChanged: function(v) { root.setMode(v) }
          }
        }

        // ---------- Fan ----------
        Column {
          visible: root.everLoaded
          width: parent.width
          spacing: Style.space(6)
          opacity: root.controlsOpacity

          PanelSectionHeader {
            text: "FAN"
            foreground: root.fg
            fontFamily: root.fontFamily
          }

          ButtonGroup {
            options: Model.FANS
            value: root.fan
            foreground: root.fg
            background: root.bar ? root.bar.background : Color.background
            fontFamily: root.fontFamily
            focusable: false
            onChanged: function(v) { root.setFan(v) }
          }
        }

        PanelSeparator {
          visible: root.everLoaded && root.zones.length > 0
          foreground: root.fg
        }

        // ---------- Rooms ----------
        Column {
          id: roomList
          visible: root.everLoaded && root.zones.length > 0
          width: parent.width
          spacing: Style.space(8)
          opacity: root.controlsOpacity

          PanelSectionHeader {
            text: "ROOMS"
            foreground: root.fg
            fontFamily: root.fontFamily
          }

          Repeater {
            model: root.zones
            ZoneRow {
              required property var modelData
              width: roomList.width
              zone: modelData
            }
          }
        }
      }
    }
  }

  // A minus / value / plus cluster. The caller owns the value and applies the
  // delta, so the same control drives the system target and each room.
  component TempStepper: Row {
    id: stepper

    property real value: NaN
    property real fontSize: Style.font.body
    property bool live: true

    signal nudged(real delta)

    spacing: Style.space(4)

    Button {
      iconText: "󰍴"
      tooltipText: ""
      foreground: root.fg
      fontFamily: root.fontFamily
      iconSize: stepper.fontSize
      horizontalPadding: Style.space(6)
      verticalPadding: Style.space(2)
      enabled: stepper.live
      opacity: stepper.live ? 1.0 : 0.5
      onClicked: stepper.nudged(-Model.TEMP_STEP)
    }

    Text {
      anchors.verticalCenter: parent.verticalCenter
      horizontalAlignment: Text.AlignHCenter
      width: Math.round(stepper.fontSize * 3.2)
      textFormat: Text.PlainText
      text: Model.formatTemp(stepper.value)
      color: root.fg
      font.family: root.fontFamily
      font.pixelSize: stepper.fontSize
      font.bold: true
    }

    Button {
      iconText: "󰐕"
      tooltipText: ""
      foreground: root.fg
      fontFamily: root.fontFamily
      iconSize: stepper.fontSize
      horizontalPadding: Style.space(6)
      verticalPadding: Style.space(2)
      enabled: stepper.live
      opacity: stepper.live ? 1.0 : 0.5
      onClicked: stepper.nudged(Model.TEMP_STEP)
    }
  }

  // One room: open/closed switch, name, its own thermometer reading, and the
  // room setpoint. The thermometer glyph marks the zone the unit is currently
  // regulating on (`myZone`).
  component ZoneRow: Item {
    id: row

    property var zone: null

    implicitHeight: Math.max(zoneSwitch.implicitHeight, zoneStepper.implicitHeight)
    opacity: (row.zone && row.zone.open) ? 1.0 : 0.55

    ToggleSwitch {
      id: zoneSwitch
      anchors.left: parent.left
      // ToggleSwitch reserves cursorPad around the track for its hover ring,
      // which would otherwise indent every room past the section headers.
      anchors.leftMargin: -(zoneSwitch.cursorRing ? zoneSwitch.cursorPad : 0)
      anchors.verticalCenter: parent.verticalCenter
      trackHeight: Style.space(18)
      checked: !!row.zone && row.zone.open
      foreground: root.fg
      onToggled: if (row.zone) root.toggleZone(row.zone.key)

      PanelToolTip {
        visible: zoneSwitch.containsMouse && !!row.zone
        text: row.zone ? ((row.zone.open ? "Close " : "Open ") + row.zone.name
              + "  ·  damper " + (isNaN(row.zone.damper) ? "--" : row.zone.damper + "%")) : ""
        fontFamily: root.fontFamily
      }
    }

    Text {
      id: zoneName
      anchors.left: zoneSwitch.right
      anchors.leftMargin: Style.space(10)
      anchors.right: measured.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: row.zone ? (row.zone.name + (row.zone.number === root.myZone ? "  󰔏" : "")) : ""
      color: root.fg
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      elide: Text.ElideRight
    }

    // Measured room temperature — the reason for the widget, so it gets the
    // accent rather than the dimmed treatment the setpoint carries.
    Text {
      id: measured
      anchors.right: zoneStepper.left
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      width: Math.round(Style.font.body * 3.4)
      horizontalAlignment: Text.AlignRight
      textFormat: Text.PlainText
      text: (row.zone && !isNaN(row.zone.measured)) ? Model.formatTemp(row.zone.measured) : ""
      color: root.fg
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      font.bold: true
    }

    TempStepper {
      id: zoneStepper
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      visible: !!row.zone && row.zone.hasSensor
      value: row.zone ? row.zone.setTemp : NaN
      fontSize: Style.font.bodySmall
      live: !!row.zone && row.zone.open && root.isOn
      onNudged: function(delta) { if (row.zone) root.nudgeZone(row.zone.key, delta) }
    }
  }
}
