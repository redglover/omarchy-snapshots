var DAY_MS = 24 * 60 * 60 * 1000

function setupState(installed, bundled) {
  var have = String(installed || "").trim()
  if (have === "") return "missing"
  return have === String(bundled || "").trim() ? "ok" : "outdated"
}

function isImportant(userdata) {
  if (!userdata) return false
  if (typeof userdata === "object") return userdata.important === "yes"
  return /(^|,)\s*important=yes\s*(,|$)/.test(String(userdata))
}

// snapper prints local time as "YYYY-MM-DD HH:MM:SS".
function parseDate(value) {
  var m = /^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2}):(\d{2})/.exec(String(value || ""))
  if (!m) return NaN
  return new Date(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +m[6]).getTime()
}

// `snapper --jsonout list` → rows, newest first, with each post snapshot
// folded into its pre. Returns null for output that isn't a snapper list, so
// a failed call never reads as "zero snapshots".
function parseList(raw) {
  var data
  try { data = JSON.parse(String(raw || "")) } catch (e) { return null }
  if (!data || typeof data !== "object") return null

  var list = null
  for (var key in data) {
    if (Array.isArray(data[key])) { list = data[key]; break }
  }
  if (!list) return null

  var byNumber = {}
  var rows = []
  for (var i = 0; i < list.length; i++) {
    var s = list[i] || {}
    var number = Number(s.number)
    if (!(number > 0)) continue // #0 is the live system
    var type = String(s.type || "single")
    var preNumber = Number(s["pre-number"])
    if (type === "post" && byNumber[preNumber]) {
      var pre = byNumber[preNumber]
      pre.post = number
      pre.important = pre.important || isImportant(s.userdata)
      continue
    }
    var row = {
      number: number,
      post: -1,
      type: type,
      date: String(s.date || ""),
      description: String(s.description || ""),
      important: isImportant(s.userdata)
    }
    byNumber[number] = row
    rows.push(row)
  }
  rows.sort(function(a, b) { return b.number - a.number })
  return rows
}

function typeLabel(row) {
  if (row.type === "pre" && row.post > 0) return "pre/post"
  return row.type
}

function numberLabel(row) {
  return row.post > 0 ? "#" + row.number + "–" + row.post : "#" + row.number
}

function relativeDate(value, nowMs) {
  var t = parseDate(value)
  if (isNaN(t)) return ""
  var s = Math.max(0, Math.floor((nowMs - t) / 1000))
  if (s < 60) return "just now"
  if (s < 3600) return Math.floor(s / 60) + " min ago"
  if (s < 86400) return Math.floor(s / 3600) + " h ago"
  var days = Math.floor(s / 86400)
  if (days === 1) return "yesterday"
  if (days < 14) return days + " days ago"
  if (days < 60) return Math.floor(days / 7) + " weeks ago"
  if (days < 730) return Math.floor(days / 30) + " months ago"
  return Math.floor(days / 365) + " years ago"
}

function newestMs(rows) {
  var newest = NaN
  for (var i = 0; i < rows.length; i++) {
    var t = parseDate(rows[i].date)
    if (!isNaN(t) && !(t <= newest)) newest = t
  }
  return newest
}

function isStale(rows, nowMs, staleDays) {
  if (!rows || rows.length === 0) return true
  var newest = newestMs(rows)
  return isNaN(newest) || nowMs - newest > staleDays * DAY_MS
}

// `snapper status a..b` lines look like "c..... /etc/motd": the first flag is
// + (created), - (deleted), or anything else for a modification.
function parseStatus(text) {
  var entries = []
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var m = /^(\S+) (\/.*)$/.exec(lines[i])
    if (!m) continue
    var flag = m[1].charAt(0)
    entries.push({ op: flag === "+" ? "added" : (flag === "-" ? "removed" : "modified"), path: m[2] })
  }
  return entries
}

var BIG_GROUP = 20

function topDir(path) {
  var parts = String(path).split("/")
  return parts.length > 2 ? "/" + parts[1] : "/"
}

// Group headers followed by their files, flattened for a single ListView.
// Big groups start collapsed; `expanded` holds the user's own choices, and a
// search opens every group so matches are never hidden.
function buildTree(entries, filter, expanded) {
  var needle = String(filter || "").toLowerCase()
  var groups = {}
  var order = []
  for (var i = 0; i < entries.length; i++) {
    var e = entries[i]
    if (needle !== "" && e.path.toLowerCase().indexOf(needle) === -1) continue
    var dir = topDir(e.path)
    if (!groups[dir]) {
      groups[dir] = { kind: "group", dir: dir, added: 0, removed: 0, modified: 0, files: [] }
      order.push(dir)
    }
    groups[dir][e.op] += 1
    groups[dir].files.push(e)
  }
  order.sort()

  var items = []
  for (var j = 0; j < order.length; j++) {
    var g = groups[order[j]]
    var open = needle !== "" || (expanded && expanded[g.dir] !== undefined ? expanded[g.dir] : g.files.length <= BIG_GROUP)
    items.push({ kind: "group", dir: g.dir, added: g.added, removed: g.removed, modified: g.modified, count: g.files.length, collapsed: !open })
    if (!open) continue
    g.files.sort(function(a, b) { return a.path < b.path ? -1 : (a.path > b.path ? 1 : 0) })
    for (var k = 0; k < g.files.length; k++)
      items.push({ kind: "file", op: g.files[k].op, path: g.files[k].path })
  }
  return items
}

// snapshots-admin diff exits 3 for files over 256 KiB; snapper's diff marks
// binary files with a "Binary files … differ" line.
function classifyDiff(text, exitCode) {
  if (exitCode === 3) return { state: "large", lines: [] }
  if (exitCode !== 0) return { state: "error", lines: [] }
  var raw = String(text || "")
  if (/^Binary files .* differ$/m.test(raw)) return { state: "binary", lines: [] }
  var lines = []
  var all = raw.split("\n")
  for (var i = 0; i < all.length; i++) {
    var line = all[i]
    if (line === "" && i === all.length - 1) break
    var kind = "ctx"
    if (/^(\+\+\+|---) /.test(line) || /^diff /.test(line)) kind = "meta"
    else if (line.indexOf("@@") === 0) kind = "hunk"
    else if (line.charAt(0) === "+") kind = "add"
    else if (line.charAt(0) === "-") kind = "del"
    lines.push({ kind: kind, text: line })
  }
  return { state: lines.length > 0 ? "text" : "empty", lines: lines }
}

// snapshots-read booted prints "snapshot N" or "none".
function parseBooted(text) {
  var m = /^snapshot (\d+)$/m.exec(String(text || ""))
  return m ? Number(m[1]) : -1
}

if (typeof module !== "undefined") {
  module.exports = {
    setupState: setupState,
    isImportant: isImportant,
    parseDate: parseDate,
    parseList: parseList,
    typeLabel: typeLabel,
    numberLabel: numberLabel,
    relativeDate: relativeDate,
    isStale: isStale,
    parseStatus: parseStatus,
    buildTree: buildTree,
    classifyDiff: classifyDiff,
    parseBooted: parseBooted
  }
}
