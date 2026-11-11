// What the drawer is willing to show. Notification text is somebody else's
// message: keep it short and plain. A click action is kept only as an argv
// that already parsed as a list of strings, never as a shell line, a URL,
// or a picture path. The panel draws every string as plain text.
.pragma library

var MAX_TEXT = 512 * 1024
var MAX_ENTRIES = 100
var MAX_SEEN = 200
var MAX_APP = 80
var MAX_SUMMARY = 240
var MAX_BODY = 400
var KEY = /^[A-Za-z0-9_-]{1,120}$/
var ICON = /^[A-Za-z0-9_.-]{1,64}$/

function bounded(value, max) {
  return typeof value === "string" ? value.slice(0, max) : ""
}

function oneLine(value, max) {
  var text = bounded(value, max)
  var out = ""
  for (var i = 0; i < text.length; i++) {
    var c = text.charCodeAt(i)
    if (c === 10 || c === 13 || c === 9) { out += " "; continue }
    if (c < 32 || (c >= 127 && c <= 159)) continue
    out += text.charAt(i)
  }
  return out.replace(/ +/g, " ").replace(/^ | $/g, "")
}

function validKey(value) {
  return typeof value === "string" && KEY.test(value)
}

function safeIcon(value) {
  var name = bounded(value, 64)
  return ICON.test(name) ? name : ""
}

// One pictograph. Anything markup-shaped, or more than one character, is dropped.
function safeGlyph(value) {
  var text = bounded(value, 8)
  if (!text || /[<>&"]/.test(text)) return ""
  var code = text.codePointAt(0)
  if (!isFinite(code)) return ""
  var chars = code > 0xffff ? 2 : 1
  if (text.length !== chars) return ""
  return text
}

function finiteTime(value) {
  var n = typeof value === "number" ? value : Number(value)
  if (!isFinite(n) || n < 1600000000 || n > 4102444800) return 0
  return n
}

// A prefix of the sender's own summary, so a later dismiss matches that toast
// and nothing else is built out of the text.
function matchText(value) {
  var text = typeof value === "string" ? value : ""
  if (text.indexOf("\u0000") >= 0) text = text.split("\u0000")[0]
  text = text.slice(0, 180)
  var out = ""
  for (var i = 0; i < text.length; i++) {
    var c = text.charCodeAt(i)
    if (c < 32 && c !== 9 && c !== 10 && c !== 13) continue
    if (c >= 127 && c <= 159) continue
    out += text.charAt(i)
  }
  return out
}

// The same structural rule the notification daemon uses: a JSON list of
// strings, a real program name, no shell line. Anything else is dropped.
function parseArgv(value) {
  var text = typeof value === "string" ? value : ""
  if (Array.isArray(value)) {
    try { text = JSON.stringify(value) } catch (e) { return [] }
  }
  if (!text || text.length > 32768 || text.charAt(0) !== "[") return []
  var parsed
  try { parsed = JSON.parse(text) } catch (e) { return [] }
  if (!Array.isArray(parsed) || parsed.length === 0 || parsed.length > 32) return []
  for (var i = 0; i < parsed.length; i++) {
    if (typeof parsed[i] !== "string" || parsed[i].length === 0 || parsed[i].length > 4096) return []
    if (parsed[i].indexOf("\u0000") >= 0) return []
  }
  if (parsed[0].charAt(0) === "-") return []
  return parsed
}

function focusName(app) {
  var name = oneLine(app, 80)
  if (!name || name.charAt(0) === "-" || !/^[A-Za-z0-9][A-Za-z0-9 ._-]{0,79}$/.test(name)) return ""
  return name
}

function entryFrom(raw) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null
  var key = bounded(raw.key, 120)
  if (!validKey(key)) return null
  var summary = oneLine(raw.summary, MAX_SUMMARY)
  var body = oneLine(raw.body, MAX_BODY)
  var app = oneLine(raw.app, MAX_APP)
  if (!summary && !body && !app) return null
  var glyph = safeGlyph(raw.glyph)
  var urgency = raw.urgency === 0 || raw.urgency === 2 ? raw.urgency : 1
  var duration = typeof raw.duration === "number" && isFinite(raw.duration) ? raw.duration : -1
  return {
    key: key,
    app: app,
    summary: summary,
    body: body,
    icon: safeIcon(raw.appIcon),
    glyph: glyph,
    omarchyGlyph: glyph.length > 0 && glyph.codePointAt(0) >= 0xe900 && glyph.codePointAt(0) <= 0xe9ff,
    urgency: urgency,
    ts: finiteTime(raw.ts) || finiteTime(raw.closed_ts),
    // duration 0 is a toast that waits forever. Everything else expires on its own.
    sticky: duration === 0,
    match: matchText(raw.summary),
    argv: parseArgv(raw.execArgv),
    focusApp: focusName(app)
  }
}

function parseList(text) {
  if (typeof text !== "string" || !text.trim()) return { ok: true, rows: [] }
  if (text.length > MAX_TEXT) return { ok: false, rows: [] }
  var parsed
  try { parsed = JSON.parse(text) } catch (e) { return { ok: false, rows: [] } }
  if (!Array.isArray(parsed)) return { ok: false, rows: [] }
  var rows = []
  var limit = Math.min(parsed.length, MAX_ENTRIES)
  for (var i = 0; i < limit; i++) {
    var row = entryFrom(parsed[i])
    if (row) rows.push(row)
  }
  return { ok: true, rows: rows }
}

// Live rows are oldest first. History is newest first. The drawer shows the
// newest live row, then the rest of what's on screen, then history.
function merge(liveRows, historyRows) {
  var out = []
  var seen = {}
  var live = liveRows || []
  var history = historyRows || []
  for (var i = live.length - 1; i >= 0; i--) {
    var row = live[i]
    if (!row || !row.key || seen[row.key]) continue
    seen[row.key] = true
    out.push(row)
  }
  for (var j = 0; j < history.length && out.length < MAX_ENTRIES; j++) {
    var hist = history[j]
    if (!hist || !hist.key || seen[hist.key]) continue
    seen[hist.key] = true
    out.push(hist)
  }
  return out
}

function keyList(value) {
  var keys = []
  var list = Array.isArray(value) ? value : []
  for (var i = 0; i < list.length && keys.length < MAX_SEEN; i++) {
    if (validKey(list[i]) && keys.indexOf(list[i]) < 0) keys.push(list[i])
  }
  return keys
}

function parseSeen(text) {
  var raw = String(text || "")
  if (!raw.trim()) return { ok: true, ready: false, keys: [], closed: [], grouped: true }
  if (raw.length > 65536) return { ok: false, ready: false, keys: [], closed: [], grouped: true }
  var read
  try { read = JSON.parse(raw) } catch (e) { return { ok: false, ready: false, keys: [], closed: [], grouped: true } }
  if (!read || typeof read !== "object" || Array.isArray(read)) return { ok: false, ready: false, keys: [], closed: [], grouped: true }
  return {
    ok: true,
    ready: read.ready === true,
    keys: keyList(read.keys),
    closed: keyList(read.closed),
    // Missing means grouped. An older file has no field, and that is the mode.
    grouped: read.grouped !== false
  }
}

function serialiseSeen(keys, closed, grouped) {
  return JSON.stringify({
    ready: true,
    keys: keyList(keys),
    closed: keyList(closed),
    grouped: grouped !== false
  }) + "\n"
}

function find(entries, key) {
  var list = entries || []
  for (var i = 0; i < list.length; i++) if (list[i] && list[i].key === key) return list[i]
  return null
}

function without(entries, closed) {
  var drop = {}
  var gone = closed || []
  for (var i = 0; i < gone.length; i++) drop[gone[i]] = true
  var out = []
  var list = entries || []
  for (var j = 0; j < list.length; j++) if (list[j] && !drop[list[j].key]) out.push(list[j])
  return out
}

// Sticky toasts older than `seconds`. The daemon already expires the rest.
function stuck(rows, now, seconds) {
  var out = []
  var list = rows || []
  var limit = Number(seconds) || 0
  for (var i = 0; i < list.length; i++) {
    var row = list[i]
    if (!row || !row.sticky || !row.match || !row.ts) continue
    if (now - row.ts < limit) continue
    out.push({ key: row.key, match: row.match })
  }
  return out
}

function keysOf(entries) {
  var out = []
  var list = entries || []
  for (var i = 0; i < list.length && out.length < MAX_SEEN; i++) {
    if (list[i] && validKey(list[i].key)) out.push(list[i].key)
  }
  return out
}

function pruneSeen(keys, entries) {
  var live = {}
  var list = entries || []
  for (var i = 0; i < list.length; i++) if (list[i] && list[i].key) live[list[i].key] = true
  var out = []
  var have = keys || []
  for (var j = 0; j < have.length && out.length < MAX_SEEN; j++) {
    if (live[have[j]]) out.push(have[j])
  }
  return out
}

function seenMap(keys) {
  var have = {}
  var known = keys || []
  for (var i = 0; i < known.length; i++) have[known[i]] = true
  return have
}

function groupId(row) {
  return (row.app || "") + "\n" + (row.summary || "")
}

// One drawer line. `keys` is every notification it stands for, newest first.
// A child is one copy inside an open group. This list never carries argv.
function shownRow(row, have) {
  var unread = !have[row.key]
  return {
    key: row.key,
    keys: [row.key],
    id: "",
    count: 1,
    child: false,
    open: false,
    app: row.app,
    summary: row.summary,
    body: row.body,
    icon: row.icon,
    glyph: row.glyph,
    omarchyGlyph: row.omarchyGlyph,
    urgency: row.urgency,
    urgent: unread && row.urgency === 2,
    unread: unread,
    ts: row.ts
  }
}

// Entries are newest first. Grouped rows share an app and a summary, and the
// line shows the newest of them. `openIds` lists group ids that are expanded,
// and those are followed by one child row per copy. A count of one never
// expands. A different app with the same summary stays separate.
function rowsFor(entries, seenKeys, grouped, openIds) {
  var list = entries || []
  var have = seenMap(seenKeys)
  var open = {}
  var ids = openIds || []
  for (var n = 0; n < ids.length; n++) if (ids[n]) open[ids[n]] = true
  if (!grouped) {
    var flat = []
    for (var i = 0; i < list.length; i++) if (list[i]) flat.push(shownRow(list[i], have))
    return flat
  }
  var order = []
  var map = {}
  for (var j = 0; j < list.length; j++) {
    var row = list[j]
    if (!row) continue
    var id = groupId(row)
    var found = map[id]
    if (!found) {
      found = shownRow(row, have)
      found.id = id
      found.members = [row]
      map[id] = found
      order.push(found)
      continue
    }
    found.keys.push(row.key)
    found.members.push(row)
    found.count++
    if (!have[row.key]) {
      found.unread = true
      if (row.urgency === 2) found.urgent = true
    }
  }
  var out = []
  for (var g = 0; g < order.length; g++) {
    var group = order[g]
    var members = group.members || []
    delete group.members
    group.open = group.count > 1 && !!open[group.id]
    out.push(group)
    if (!group.open) continue
    for (var m = 0; m < members.length; m++) {
      var child = shownRow(members[m], have)
      child.child = true
      child.id = group.id
      out.push(child)
    }
  }
  return out
}

function unreadCount(entries, keys) {
  var have = {}
  var known = keys || []
  for (var i = 0; i < known.length; i++) have[known[i]] = true
  var n = 0
  var list = entries || []
  for (var j = 0; j < list.length; j++) if (list[j] && !have[list[j].key]) n++
  return n
}

function parseQuiet(text) {
  var raw = String(text || "")
  if (!raw.trim()) return { ok: true, dnd: false }
  if (raw.length > 4096) return { ok: false, dnd: false }
  var read
  try { read = JSON.parse(raw) } catch (e) { return { ok: false, dnd: false } }
  if (!read || typeof read !== "object" || Array.isArray(read)) return { ok: false, dnd: false }
  return { ok: true, dnd: read.dnd === true }
}
