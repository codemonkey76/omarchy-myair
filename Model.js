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

// ---- Limits on device input ----------------------------------------------
// Everything under /getSystemData is attacker-controlled the moment the tablet
// is spoofed or compromised: it is a consumer appliance on the LAN, not a
// trusted peer. curl caps the bytes it will read off the socket (see the
// --max-filesize arguments in Panel.qml); these caps bound what the document
// can then cost the shell, which is a long-lived process the widget shares.
//
// For scale, a real MyAir5 with five zones serves 3,950 bytes at depth 6.
var MAX_DOC_BYTES = 131072   // /getSystemData — ~33x the observed document
var MAX_ACK_BYTES = 8192     // /setAircon — a one-line acknowledgement
var MAX_DEPTH = 12           // observed 6
var MAX_AIRCONS = 8          // observed 1
var MAX_ZONES = 32           // a MyAir5 system tops out at 10
var MAX_NAME = 64            // the tablet's own name fields stop well short
var MAX_REASON = 200         // ack:false explanation

// Device-supplied strings reach QML labels and tooltips. Truncate, then drop
// control characters, line separators and bidi overrides, so that a name
// cannot break out of its row, pad a tooltip with blank lines, or visually
// reorder the text around it.
function safeText(value, limit) {
  if (typeof value !== "string") return ""
  var s = value.length > limit ? value.substring(0, limit) : value
  return s.replace(/[\u0000-\u001F\u007F-\u009F\u2028\u2029\u200E\u200F\u202A-\u202E\u2066-\u2069]/g, "")
}

// Nesting is counted on the raw text, before JSON.parse is handed it: deeply
// nested input is cheap to send and expensive to parse. Quoted spans are
// skipped so braces inside a zone name cannot inflate the count.
function depthOk(text) {
  var depth = 0
  var inString = false
  for (var i = 0; i < text.length; i++) {
    var c = text.charAt(i)
    if (inString) {
      if (c === "\\") i++
      else if (c === "\"") inString = false
    } else if (c === "\"") {
      inString = true
    } else if (c === "{" || c === "[") {
      if (++depth > MAX_DEPTH) return false
    } else if (c === "}" || c === "]") {
      depth--
    }
  }
  return true
}

// The single gate every response passes: size, then nesting, then parse.
// Returns null rather than throwing, because every caller already treats null
// as "keep the last good reading".
//
// A JS string length is UTF-16 code units, which is never more than the UTF-8
// byte count curl measured, so this check can only ever be stricter than the
// ceiling already enforced on the wire — it is the backstop for a curl too old
// to abort a chunked response mid-transfer, not the primary limit.
function parseGuarded(raw, maxBytes) {
  var text = String(raw || "").trim()
  if (!text || text.length > maxBytes) return null
  if (!depthOk(text)) return null
  try {
    return JSON.parse(text)
  } catch (e) {
    return null
  }
}

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

// Unknown values are echoed rather than blanked, so a firmware that grows a
// new mode still reads sensibly — but echoed means device-supplied, so it is
// bounded and stripped like any other name.
function labelFor(list, value) {
  for (var i = 0; i < list.length; i++)
    if (list[i].value === value) return list[i].label
  return value ? safeText(String(value), MAX_NAME) : ""
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
  var doc = parseGuarded(raw, MAX_DOC_BYTES)
  if (!doc || !doc.aircons) return null

  // A document claiming more units than a MyAir can have is not a MyAir.
  if (Object.keys(doc.aircons).length > MAX_AIRCONS) return null

  var ac = doc.aircons[acKey]
  if (!ac || !ac.info || typeof ac.info.state !== "string") return null

  // `name` is the only info field rendered verbatim; every other one is either
  // matched against a known vocabulary or coerced to a number.
  ac.info.name = safeText(ac.info.name, MAX_NAME)
  return ac
}

function acKeys(raw) {
  var doc = parseGuarded(raw, MAX_DOC_BYTES)
  if (!doc || !doc.aircons) return []
  var keys = Object.keys(doc.aircons)
  return keys.length > MAX_AIRCONS ? [] : keys.sort()
}

// Zones in tablet order (z01, z02, ...), flattened to what the rows need.
// `type` 1 means the zone owns a temperature sensor and is driven by a
// setpoint; type 0 zones are damper-percentage only and get no stepper.
function zoneList(ac) {
  if (!ac || !ac.zones) return []

  var keys = Object.keys(ac.zones).sort()
  if (keys.length > MAX_ZONES) keys = keys.slice(0, MAX_ZONES)

  var out = []
  for (var i = 0; i < keys.length; i++) {
    var z = ac.zones[keys[i]]
    if (!z || typeof z.name !== "string") continue
    // Fall back to the tablet's own key rather than dropping the row: a zone
    // whose name is entirely stripped should still be openable.
    var name = safeText(z.name, MAX_NAME) || keys[i]
    out.push({
      key: keys[i],
      name: name,
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

// setAircon answers {"ack":true} or {"ack":false,"reason":...}. The reason is
// shown in the panel, so it is bounded and stripped like any other device
// string. Empty return means "nothing to report".
function parseAck(raw) {
  var doc = parseGuarded(raw, MAX_ACK_BYTES)
  if (!doc || doc.ack !== false) return ""
  return safeText(String(doc.reason || ""), MAX_REASON) || "Rejected"
}
