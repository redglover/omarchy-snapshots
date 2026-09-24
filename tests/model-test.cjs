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

// parseStatus
const status = [
  "c..... /etc/motd",
  "+..... /etc/pacman.d/new list",
  "-..... /etc/gone.conf",
  "..p... /usr/bin/perm-only",
  "+..... /swapfile",
  "",
  "garbage line"
].join("\n")
const entries = Model.parseStatus(status)
assert.deepEqual(entries, [
  { op: "modified", path: "/etc/motd" },
  { op: "added", path: "/etc/pacman.d/new list" },
  { op: "removed", path: "/etc/gone.conf" },
  { op: "modified", path: "/usr/bin/perm-only" },
  { op: "added", path: "/swapfile" }
])

// buildTree: grouped by top-level dir, sorted, counted
{
  const items = Model.buildTree(entries, "", {})
  assert.deepEqual(items.filter(i => i.kind === "group").map(g => [g.dir, g.added, g.removed, g.modified, g.count]), [
    ["/", 1, 0, 0, 1],
    ["/etc", 1, 1, 1, 3],
    ["/usr", 0, 0, 1, 1]
  ])
  assert.deepEqual(items.map(i => i.kind === "group" ? "G " + i.dir : i.path), [
    "G /", "/swapfile",
    "G /etc", "/etc/gone.conf", "/etc/motd", "/etc/pacman.d/new list",
    "G /usr", "/usr/bin/perm-only"
  ])
}

// buildTree: big groups start collapsed, user choice and search override
{
  const many = []
  for (let i = 0; i < 25; i++) many.push({ op: "added", path: `/var/cache/f${i}` })
  many.push({ op: "modified", path: "/etc/motd" })
  let items = Model.buildTree(many, "", {})
  const varGroup = items.find(i => i.dir === "/var")
  assert.equal(varGroup.collapsed, true)
  assert.equal(varGroup.count, 25)
  assert.equal(items.filter(i => i.kind === "file" && i.path.startsWith("/var")).length, 0)
  assert.equal(items.find(i => i.dir === "/etc").collapsed, false)

  items = Model.buildTree(many, "", { "/var": true, "/etc": false })
  assert.equal(items.filter(i => i.kind === "file").length, 25)

  items = Model.buildTree(many, "F1", {})
  assert.deepEqual(items.filter(i => i.kind === "file").map(i => i.path),
    ["/var/cache/f1", "/var/cache/f10", "/var/cache/f11", "/var/cache/f12", "/var/cache/f13", "/var/cache/f14", "/var/cache/f15", "/var/cache/f16", "/var/cache/f17", "/var/cache/f18", "/var/cache/f19"],
    "search is case-insensitive, opens collapsed groups, and hides non-matching groups")
  assert.equal(items.filter(i => i.kind === "group").length, 1)
}

// classifyDiff
{
  const diff = [
    "--- /.snapshots/5/snapshot/etc/motd\t2026-09-20 10:00:00",
    "+++ /etc/motd\t2026-09-24 11:00:00",
    "@@ -1,2 +1,2 @@",
    " Welcome",
    "-old line",
    "+new line",
    ""
  ].join("\n")
  const d = Model.classifyDiff(diff, 0)
  assert.equal(d.state, "text")
  assert.deepEqual(d.lines.map(l => l.kind), ["meta", "meta", "hunk", "ctx", "del", "add"])
  assert.equal(Model.classifyDiff("Binary files /.snapshots/5/snapshot/usr/bin/x and /usr/bin/x differ\n", 0).state, "binary")
  assert.equal(Model.classifyDiff("", 3).state, "large")
  assert.equal(Model.classifyDiff("", 0).state, "empty")
  assert.equal(Model.classifyDiff("", 2).state, "error")
}

// parseBooted
assert.equal(Model.parseBooted("snapshot 12\n"), 12)
assert.equal(Model.parseBooted("none\n"), -1)
assert.equal(Model.parseBooted(""), -1)

console.log("model-test: ok")
