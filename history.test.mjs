import assert from "node:assert/strict"
import fs from "node:fs"

const src = fs.readFileSync(new URL("./History.js", import.meta.url), "utf8")
  .split("\n")
  .filter((line) => !line.startsWith("."))
  .join("\n")
const History = new Function(src + `
  return { parseList, merge, parseSeen, serialiseSeen, keysOf, pruneSeen, unreadCount, parseQuiet, validKey, entryFrom, without, stuck, find, rowsFor }
`)()

const markup = '<img src="https://example.invalid/tracker">'
const parsed = History.parseList(JSON.stringify([
  {
    key: "abc_1",
    app: "Mail",
    summary: markup,
    body: "<b>hello</b>\nsecond line",
    appIcon: "image://icon/evil",
    glyph: "<img>",
    execArgv: '["sh","-c","evil"]',
    execActions: '[{"label":"Run","argv":["sh"]}]',
    link: "https://example.invalid/tracker",
    image: "/etc/passwd",
    urgency: 2,
    ts: 1794428193
  },
  { key: "../etc", summary: "nope", ts: 1794428193 },
  { key: "ok-2", summary: "Plain", body: "Body", appIcon: "firefox", glyph: "\u{f009a}", ts: 1794428200 }
]))

assert.equal(parsed.ok, true)
assert.equal(parsed.rows.length, 2)
const marked = parsed.rows[0]
assert.equal(marked.summary, markup)
assert.equal(marked.body, "<b>hello</b> second line")
assert.equal(marked.icon, "")
assert.equal(marked.glyph, "")
assert.equal(marked.urgency, 2)
assert.equal("execArgv" in marked, false)
assert.equal("execActions" in marked, false)
assert.equal("link" in marked, false)
assert.equal("image" in marked, false)
assert.deepEqual(marked.argv, ["sh", "-c", "evil"])
assert.equal(marked.match, markup)
assert.equal(marked.focusApp, "Mail")
assert.equal(marked.sticky, false)

const shellLine = History.entryFrom({ key: "k1", summary: "S", execArgv: "rm -rf /", ts: 1794428193 })
assert.deepEqual(shellLine.argv, [])
const dashed = History.entryFrom({ key: "k2", summary: "S", execArgv: '["-rf","/"]', ts: 1794428193 })
assert.deepEqual(dashed.argv, [])
const opener = History.entryFrom({
  key: "k3", summary: "Process crashed: ffmpeg", body: "Click to diagnose",
  execArgv: '["omarchy-agent-crash","1","ffmpeg"]', duration: 0, ts: 1794428193
})
assert.deepEqual(opener.argv, ["omarchy-agent-crash", "1", "ffmpeg"])
assert.equal(opener.sticky, true)
assert.equal(opener.match.indexOf("Click to diagnose"), -1)
assert.equal(parsed.rows[1].icon, "firefox")
assert.equal(parsed.rows[1].glyph, "\u{f009a}")

assert.equal(History.parseList("x".repeat(512 * 1024 + 1)).ok, false)
assert.equal(History.parseList("not json").ok, false)
assert.deepEqual(History.parseList("").rows, [])

const merged = History.merge(
  [{ key: "live-old", summary: "old" }, { key: "live-new", summary: "new" }],
  [{ key: "live-new", summary: "dup" }, { key: "hist", summary: "past" }]
)
assert.deepEqual(merged.map((row) => row.key), ["live-new", "live-old", "hist"])

const seen = History.parseSeen(History.serialiseSeen(["abc_1", "../nope", "abc_1", "ok-2"]))
assert.equal(seen.ready, true)
assert.deepEqual(seen.keys, ["abc_1", "ok-2"])
assert.equal(History.unreadCount(parsed.rows, seen.keys), 0)
assert.equal(History.unreadCount(parsed.rows, ["abc_1"]), 1)
assert.deepEqual(History.pruneSeen(["abc_1", "gone"], parsed.rows), ["abc_1"])
assert.equal(History.parseSeen("<img>").ok, false)
const stored = History.parseSeen(History.serialiseSeen(["abc_1"], ["ok-2", "../nope"]))
assert.deepEqual(stored.closed, ["ok-2"])
assert.deepEqual(History.without(parsed.rows, ["abc_1"]).map((row) => row.key), ["ok-2"])
const now = 1794428300
assert.deepEqual(History.stuck([
  { key: "old", sticky: true, match: "Process crashed", ts: now - 9 },
  { key: "fresh", sticky: true, match: "Process crashed", ts: now - 2 },
  { key: "normal", sticky: false, match: "Hello", ts: now - 30 }
], now, 8).map((row) => row.key), ["old"])
assert.deepEqual(History.parseQuiet('{"dnd":true}'), { ok: true, dnd: true })
assert.deepEqual(History.parseQuiet(""), { ok: true, dnd: false })

const legacy = History.parseSeen('{"ready":true,"keys":["abc_1"],"closed":[]}\n')
assert.equal(legacy.grouped, true)
const ungrouped = History.parseSeen(History.serialiseSeen(["abc_1"], [], false))
assert.equal(ungrouped.grouped, false)
assert.equal(History.parseSeen(History.serialiseSeen(["abc_1"], [])).grouped, true)

const pile = [
  { key: "d", app: "Superwhisper", summary: "Process crashed: ffmpeg", body: "sw", urgency: 1, ts: 4 },
  { key: "a", app: "omarchy-action", summary: "Process crashed: ffmpeg", body: "new", urgency: 1, ts: 3 },
  { key: "b", app: "omarchy-action", summary: "Process crashed: ffmpeg", body: "old", urgency: 2, ts: 2 },
  { key: "c", app: "omarchy-action", summary: "Process crashed: nautilus", body: "n", urgency: 2, ts: 1 }
]
const groups = History.rowsFor(pile, ["a"], true)
assert.equal(groups.length, 3)
assert.equal(groups[0].key, "d")
assert.equal(groups[0].count, 1)
assert.equal(groups[1].count, 2)
assert.equal(groups[1].key, "a")
assert.deepEqual(groups[1].keys, ["a", "b"])
assert.equal(groups[1].body, "new")
assert.equal(groups[1].unread, true)
assert.equal(groups[1].urgent, true)
assert.equal(groups[1].summary, "Process crashed: ffmpeg")
assert.equal(groups[2].key, "c")
assert.equal("argv" in groups[1], false)
const flat = History.rowsFor(pile, ["a"], false)
assert.equal(flat.length, 4)
assert.equal(flat[1].count, 1)
assert.equal(flat[1].unread, false)
assert.equal(flat[2].urgent, true)
const markedGroup = History.rowsFor([
  { key: "m1", app: "Mail", summary: markup, urgency: 1 },
  { key: "m2", app: "Mail", summary: markup, urgency: 1 }
], [], true)
assert.equal(markedGroup.length, 1)
assert.equal(markedGroup[0].count, 2)
assert.equal(markedGroup[0].summary, markup)

const crashId = "omarchy-action\nProcess crashed: ffmpeg"
const opened = History.rowsFor(pile, ["a"], true, [crashId])
assert.equal(opened.length, 5)
assert.equal(opened[1].open, true)
assert.equal(opened[1].child, false)
assert.equal(opened[2].child, true)
assert.equal(opened[2].key, "a")
assert.equal(opened[2].body, "new")
assert.equal(opened[3].child, true)
assert.equal(opened[3].key, "b")
assert.equal(opened[3].body, "old")
assert.equal(opened[3].urgent, true)
assert.equal(opened[4].key, "c")
assert.equal(opened[4].child, false)
const single = History.rowsFor(pile, [], true, ["Superwhisper\nProcess crashed: ffmpeg"])
assert.equal(single.length, 3)
assert.equal(single[0].open, false)
assert.equal(History.rowsFor(pile, ["a"], false, [crashId]).length, 4)

console.log("history tests ok")
