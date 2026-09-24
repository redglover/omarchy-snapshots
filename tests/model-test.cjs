const assert = require("node:assert/strict")
const path = require("node:path")
const Model = require(path.join(__dirname, "..", "Model.js"))

const DAY = 24 * 60 * 60 * 1000
const now = new Date(2026, 8, 24, 12, 0, 0).getTime()

// Shape of `snapper -c root --jsonout list` (snapper 0.10+).
const list = JSON.stringify({
  root: [
    { number: 0, default: false, active: false, type: "single", "pre-number": null, date: "", user: "root", cleanup: "", description: "current", userdata: null },
    { number: 1, type: "single", "pre-number": null, date: "2026-09-01 09:00:00", cleanup: "number", description: "3.9.0", userdata: null },
    { number: 2, type: "pre", "pre-number": null, date: "2026-09-20 10:00:00", cleanup: "number", description: "pacman -Syu", userdata: null },
    { number: 3, type: "post", "pre-number": 2, date: "2026-09-20 10:02:00", cleanup: "number", description: "pacman -Syu", userdata: { important: "yes" } },
    { number: 4, type: "single", "pre-number": null, date: "2026-09-24 11:58:30", cleanup: "number", description: "before tweak", userdata: { important: "yes" } },
    { number: 6, type: "post", "pre-number": 5, date: "2026-09-24 11:59:00", cleanup: "number", description: "orphan post", userdata: null }
  ]
})

// parseList: drops #0, folds post into pre, newest first
{
  const rows = Model.parseList(list)
  assert.deepEqual(rows.map(r => r.number), [6, 4, 2, 1])
  const pair = rows.find(r => r.number === 2)
  assert.equal(pair.post, 3)
  assert.equal(Model.typeLabel(pair), "pre/post")
  assert.equal(Model.numberLabel(pair), "#2–3")
  assert.equal(pair.important, true, "important on the post marks the pair")
  assert.equal(rows.find(r => r.number === 4).important, true)
  assert.equal(rows.find(r => r.number === 1).important, false)
  assert.equal(Model.typeLabel(rows.find(r => r.number === 6)), "post", "post without its pre stays its own row")
  assert.equal(Model.numberLabel(rows.find(r => r.number === 1)), "#1")
}

// parseList: failure is not "zero snapshots"
assert.equal(Model.parseList(""), null)
assert.equal(Model.parseList("No permissions."), null)
assert.deepEqual(Model.parseList(JSON.stringify({ root: [{ number: 0 }] })), [])

// isImportant: object and legacy string userdata
assert.equal(Model.isImportant({ important: "yes" }), true)
assert.equal(Model.isImportant({ important: "no" }), false)
assert.equal(Model.isImportant("foo=bar, important=yes"), true)
assert.equal(Model.isImportant(null), false)

// relativeDate
const at = ms => {
  const d = new Date(now - ms)
  const p = n => String(n).padStart(2, "0")
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`
}
assert.equal(Model.relativeDate(at(10 * 1000), now), "just now")
assert.equal(Model.relativeDate(at(5 * 60 * 1000), now), "5 min ago")
assert.equal(Model.relativeDate(at(3 * 3600 * 1000), now), "3 h ago")
assert.equal(Model.relativeDate(at(DAY + 1000), now), "yesterday")
assert.equal(Model.relativeDate(at(4 * DAY), now), "4 days ago")
assert.equal(Model.relativeDate(at(21 * DAY), now), "3 weeks ago")
assert.equal(Model.relativeDate(at(90 * DAY), now), "3 months ago")
assert.equal(Model.relativeDate(at(-60 * 1000), now), "just now", "clock skew never reads as the future")
assert.equal(Model.relativeDate("", now), "")

// isStale
{
  const rows = Model.parseList(list)
  assert.equal(Model.isStale([], now, 14), true, "no snapshots warns")
  assert.equal(Model.isStale(rows, now, 14), false)
  assert.equal(Model.isStale(rows.filter(r => r.number === 1), now, 14), true, "23 days old warns at 14")
  assert.equal(Model.isStale(rows.filter(r => r.number === 1), now, 30), false)
}

// setupState
assert.equal(Model.setupState("", "1"), "missing")
assert.equal(Model.setupState("1\n", "1"), "ok")
assert.equal(Model.setupState("1", "2"), "outdated")

console.log("model-test: ok")
