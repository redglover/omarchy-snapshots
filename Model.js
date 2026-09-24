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

if (typeof module !== "undefined") {
  module.exports = {
    setupState: setupState,
    isImportant: isImportant,
    parseDate: parseDate,
    parseList: parseList,
    typeLabel: typeLabel,
    numberLabel: numberLabel,
    relativeDate: relativeDate,
    isStale: isStale
  }
}
