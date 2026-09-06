.pragma library

// Advantage Air MyAir5 local HTTP API, served by the wall tablet on port 2025.
//
//   GET /getSystemData                -> full system document
//   GET /setAircon?json=<patch>       -> {"ack":true} | {"ack":false,"reason":...}
//
// The vocabulary below was probed against the unit rather than assumed. The
// tablet validates enum values and answers ack:false without applying, which
// ruled out the plausible-looking "med" (it wants "medium") and "fan" (it
// wants "vent"). setTemp is the exception: it acks *any* number, including 35
// and -5, so the clamp here is the only thing keeping the setpoint sane.

var MODES = [
  { value: "cool", label: "Cool", icon: "󰜗" },
  { value: "heat", label: "Heat", icon: "󰈸" },
  { value: "vent", label: "Vent", icon: "󰈐" },
  { value: "dry",  label: "Dry",  icon: "󰖎" }
]

var FANS = [
  { value: "low",    label: "Low" },
  { value: "medium", label: "Med" },
  { value: "high",   label: "High" },
  { value: "auto",   label: "Auto" }
]

var ICON_IDLE = "󰀛"   // air-conditioner, for off
var ICON_DOWN = "󰌙"   // lan-disconnect, for unreachable

var TEMP_MIN = 16
var TEMP_MAX = 32
var TEMP_STEP = 0.5

function clampTemp(value) {
  var t = Number(value)
  if (isNaN(t)) return 24
  t = Math.round(t / TEMP_STEP) * TEMP_STEP
  return Math.max(TEMP_MIN, Math.min(TEMP_MAX, t))
}

// Whole degrees lose the decimal: "24°", not "24.0°". Halves keep it.
function formatTemp(value) {
  var t = Number(value)
  if (isNaN(t)) return "--"
  return (Math.abs(t - Math.round(t)) < 0.05 ? String(Math.round(t)) : t.toFixed(1)) + "°"
}

function labelFor(list, value) {
  for (var i = 0; i < list.length; i++)
    if (list[i].value === value) return list[i].label
  return value ? String(value) : ""
}

function modeIcon(mode) {
  for (var i = 0; i < MODES.length; i++)
    if (MODES[i].value === mode) return MODES[i].icon
  return ICON_IDLE
}

// The tablet serves a *stripped* document while it is applying a change: the
// keys are all still there but their values are null. Polling right after a
// command reliably hits it. Returning null for that case (rather than an
// object full of nulls) is what stops every button press from blanking the
// panel for a second.
function parseAircon(raw, acKey) {
  var text = String(raw || "").trim()
  if (!text) return null

  var doc
  try {
    doc = JSON.parse(text)
  } catch (e) {
    return null
  }

  if (!doc || !doc.aircons) return null
  var ac = doc.aircons[acKey]
  if (!ac || !ac.info || typeof ac.info.state !== "string") return null
  return ac
}

function acKeys(raw) {
  try {
    var doc = JSON.parse(String(raw || ""))
    return (doc && doc.aircons) ? Object.keys(doc.aircons).sort() : []
  } catch (e) {
    return []
  }
}

// Zones in tablet order (z01, z02, ...), flattened to what the rows need.
// `type` 1 means the zone owns a temperature sensor and is driven by a
// setpoint; type 0 zones are damper-percentage only and get no stepper.
function zoneList(ac) {
  if (!ac || !ac.zones) return []

  var keys = Object.keys(ac.zones).sort()
  var out = []
  for (var i = 0; i < keys.length; i++) {
    var z = ac.zones[keys[i]]
    if (!z || typeof z.name !== "string") continue
    out.push({
      key: keys[i],
      name: z.name,
      number: Number(z.number),
      open: z.state === "open",
      setTemp: Number(z.setTemp),
      measured: (typeof z.measuredTemp === "number") ? z.measuredTemp : NaN,
      damper: Number(z.value),
      hasSensor: Number(z.type) === 1,
      error: Number(z.error) || 0
    })
  }
  return out
}

// One-line summary under the panel title, and the body of the bar tooltip.
function statusLine(reachable, on, mode, fan) {
  if (!reachable) return "Unreachable"
  if (!on) return "Off"
  return labelFor(MODES, mode).toUpperCase() + " · FAN " + labelFor(FANS, fan).toUpperCase()
}

function tooltip(reachable, on, mode, fan, setTemp, zones) {
  if (!reachable) return "MyAir — unreachable"
  if (!on) return "MyAir — off"

  var head = "MyAir — " + labelFor(MODES, mode) + " " + formatTemp(setTemp)
    + " · fan " + labelFor(FANS, fan).toLowerCase()
  var lines = [head]
  for (var i = 0; i < zones.length; i++) {
    var z = zones[i]
    if (!z.open) continue
    lines.push(z.name + "  " + (isNaN(z.measured) ? "--" : formatTemp(z.measured)))
  }
  return lines.join("\n")
}
