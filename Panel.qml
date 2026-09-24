import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "io.github.redglover.snapshots"
  ipcTarget: "snapshots"

  // pkexec only ever runs the root-owned installed copies. The plugin folder
  // is user-writable, so running a helper from it as root would hand root to
  // anything that can edit that folder. setup is the one exception: it is the
  // step that installs those copies, and polkit asks for an admin password.
  readonly property string installDir: "/usr/local/lib/omarchy-snapshots"
  readonly property string readHelper: installDir + "/snapshots-read"
  readonly property string adminHelper: installDir + "/snapshots-admin"
  readonly property string pluginHelperDir: decodeURIComponent(String(Qt.resolvedUrl("helper")).replace(/^file:\/\//, ""))
  readonly property string config: "root"
  readonly property int staleDays: Number(setting("staleDays", 14)) || 14

  property string installedVersion: ""
  property string bundledVersion: ""
  readonly property string setupState: Model.setupState(installedVersion, bundledVersion)
  property var rows: []
  property bool listLoaded: false
  property string error: ""
  property real nowMs: Date.now()
  property int cursor: 0

  property var selected: null
  property var changes: []
  property string filter: ""
  property var expanded: ({})
  readonly property var treeItems: Model.buildTree(changes, filter, expanded)
  property string diffPath: ""
  property var diff: null
  property int diffReturnCursor: 0
  property var checked: ({})
  readonly property var checkedPaths: Object.keys(checked).sort()

  property string confirmAction: ""
  property string confirmMessage: ""
  property string confirmLabel: ""
  property bool enterPressed: false
  property int bootedSnapshot: -1
  property bool promoteStarted: false
  property var pendingDelete: null
  readonly property string view: setupState !== "ok" ? "setup"
    : (diffPath !== "" ? "diff" : (selected ? "changes" : "list"))

  readonly property bool stale: listLoaded && Model.isStale(rows, nowMs, staleDays)
  readonly property bool warning: setupState !== "ok" || stale
  readonly property color dim: Qt.darker(root.bar.foreground, 1.5)

  function refresh() {
    nowMs = Date.now()
    installedFile.reload()
    bundledFile.reload()
    if (setupState === "ok") {
      loadList()
      if (!bootedProc.running) bootedProc.start(["pkexec", readHelper, "booted"])
    }
  }

  function loadList() {
    if (listProc.running) return
    listProc.start(["pkexec", readHelper, "list", config])
  }

  function runSetup() {
    if (setupProc.running) return
    error = ""
    setupProc.start(["pkexec", pluginHelperDir + "/setup"])
  }

  // pkexec exits 126 when the password prompt is dismissed: a choice, not an
  // error. Returns whether an error was shown.
  function failed(what, err, code) {
    if (code === 126) return false
    var text = String(err || "").trim()
    error = text !== "" ? text : what + " failed"
    return true
  }

  function openSnapshot(row) {
    if (!row) return
    selected = row
    changes = []
    checked = ({})
    filter = ""
    expanded = ({})
    cursor = 0
    loadChanges()
  }

  // Status can take a while on old snapshots; if the user moved on to another
  // snapshot meanwhile, onDone starts over for the current one.
  function loadChanges() {
    if (!selected || statusProc.running) return
    statusProc.number = selected.number
    statusProc.start(["pkexec", readHelper, "status", config, String(selected.number), "0"])
  }

  function openDiff(path) {
    diffReturnCursor = cursor
    diffPath = path
    diff = null
    loadDiff()
  }

  function loadDiff() {
    if (diffPath === "" || diffProc.running) return
    diffProc.path = diffPath
    diffProc.start(["pkexec", adminHelper, "diff", config, String(selected.number), "0", diffPath])
  }

  function toggleChecked(path) {
    var next = Object.assign({}, checked)
    if (next[path]) delete next[path]
    else next[path] = true
    checked = next
  }

  function notify(headline, description) {
    Quickshell.execDetached(["omarchy-notification-send", "-g", "\u{f006f}", headline, description])
  }

  function ask(action, message, label) {
    confirmAction = action
    confirmMessage = message
    confirmLabel = label
    confirmDialog.selectedIndex = 0
    confirmDialog.forceActiveFocus()
  }

  function dismissConfirm() {
    confirmAction = ""
    keyCatcher.forceActiveFocus()
  }

  function confirmed() {
    var action = confirmAction
    dismissConfirm()
    if (action === "restore") restoreChecked()
    else if (action === "promote") promote()
    else if (action === "delete") manage(["delete", config].concat(snapshotNumbers(pendingDelete)))
    else if (action === "reboot") Quickshell.execDetached(["omarchy-system-reboot"])
  }

  // limine-snapper-restore is interactive (it confirms, then asks about
  // rebooting), so it gets a terminal. The command is a constant: nothing
  // user-controlled reaches the shell string.
  function promote() {
    Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation", "pkexec " + adminHelper + " promote"])
    promoteStarted = true
  }

  function askRestore() {
    var paths = checkedPaths
    if (!selected || paths.length === 0) return
    var shown = paths.slice(0, 8).join("\n")
    if (paths.length > 8) shown += "\n… and " + (paths.length - 8) + " more"
    // Files added since the snapshot didn't exist then, so restoring removes them.
    var added = changes.filter(function(e) { return e.op === "added" && checked[e.path] }).length
    ask("restore", "Restore " + paths.length + (paths.length === 1 ? " file" : " files") + " from snapshot #" + selected.number
      + "?" + (added > 0 ? " " + added + (added === 1 ? " was" : " were") + " added since then and will be deleted." : "")
      + " The current versions are saved in a new snapshot first.\n\n" + shown, "Restore")
  }

  function restoreChecked() {
    if (undoProc.running) return
    undoProc.number = selected.number
    undoProc.count = checkedPaths.length
    undoProc.start(["pkexec", adminHelper, "undo", config, String(selected.number)].concat(checkedPaths))
  }

  function snapshotNumbers(row) {
    return row.post > 0 ? [String(row.number), String(row.post)] : [String(row.number)]
  }

  function manage(args) {
    if (manageProc.running) return
    manageProc.args = args
    manageProc.start(["pkexec", adminHelper].concat(args))
  }

  function createSnapshot() {
    var description = descField.text.trim()
    if (description === "") description = "Manual snapshot"
    manage(["create", config, description])
  }

  function askDelete(row) {
    if (!row) return
    pendingDelete = row
    ask("delete", "Delete snapshot " + Model.numberLabel(row) + (row.description ? " (" + row.description + ")" : "")
      + "? This can't be undone.", "Delete")
  }

  function toggleImportant(row) {
    if (row) manage(["important", config, row.important ? "no" : "yes"].concat(snapshotNumbers(row)))
  }

  function toggleGroup(dir, collapsed) {
    var next = Object.assign({}, expanded)
    next[dir] = collapsed
    expanded = next
  }

  function back() {
    if (view === "diff") {
      diffPath = ""
      cursor = diffReturnCursor
    } else if (view === "changes") {
      var number = selected.number
      var index = rows.findIndex(function(r) { return r.number === number })
      selected = null
      filter = ""
      cursor = Math.max(0, index)
    } else {
      close()
    }
  }

  function itemCount() {
    return view === "changes" ? treeItems.length : (view === "list" ? rows.length : 0)
  }

  function moveCursor(delta) {
    if (view === "diff") {
      diffList.contentY = Math.max(0, Math.min(diffList.contentHeight - diffList.height, diffList.contentY + delta * Style.space(48)))
      return
    }
    cursor = Math.max(0, Math.min(itemCount() - 1, cursor + delta))
  }

  // PanelKeyCatcher sends Enter and Space both as activate; Enter also
  // fires returnRequested first, which is how Space gets to mean "select".
  function keyActivate() {
    var enter = enterPressed
    enterPressed = false
    var item = view === "changes" ? treeItems[cursor] : null
    if (!enter && item && item.kind === "file") toggleChecked(item.path)
    else activate()
  }

  function activate() {
    if (view === "setup") runSetup()
    else if (view === "list") openSnapshot(rows[cursor])
    else if (view === "changes") {
      var item = treeItems[cursor]
      if (item && item.kind === "group") toggleGroup(item.dir, item.collapsed)
      else if (item) openDiff(item.path)
    }
  }

  onSetupStateChanged: if (setupState === "ok") refresh()
  onOpenedChanged: if (opened) { refresh(); cursor = 0 }
  onFilterChanged: cursor = 0

  // Keeps the bar's stale dot honest without the panel being opened.
  Timer { interval: 30 * 60 * 1000; running: true; repeat: true; onTriggered: root.refresh() }

  FileView {
    id: installedFile
    path: root.installDir + "/VERSION"
    printErrors: false
    onLoaded: root.installedVersion = text().trim()
    onLoadFailed: root.installedVersion = ""
  }

  FileView {
    id: bundledFile
    path: root.pluginHelperDir + "/VERSION"
    onLoaded: root.bundledVersion = text().trim()
  }

  HelperProc {
    id: listProc
    onDone: function(code, out, err) {
      var parsed = code === 0 ? Model.parseList(out) : null
      if (!parsed) { root.failed("Listing snapshots", err, code); return }
      root.error = ""
      root.rows = parsed
      root.listLoaded = true
      root.cursor = Math.min(root.cursor, Math.max(0, parsed.length - 1))
    }
  }

  HelperProc {
    id: statusProc
    property int number: -1
    onDone: function(code, out, err) {
      if (!root.selected) return
      if (number !== root.selected.number) { root.loadChanges(); return }
      if (code !== 0) { root.failed("Comparing snapshot", err, code); return }
      root.error = ""
      root.changes = Model.parseStatus(out)
    }
  }

  HelperProc {
    id: diffProc
    property string path: ""
    onDone: function(code, out, err) {
      if (root.diffPath === "") return
      if (path !== root.diffPath) { root.loadDiff(); return }
      if (code === 126) { root.back(); return }
      root.diff = Model.classifyDiff(out, code)
      if (root.diff.state === "error") root.failed("Diff", err, code)
    }
  }

  HelperProc {
    id: undoProc
    property int number: -1
    property int count: 0
    onDone: function(code, out, err) {
      var what = count + (count === 1 ? " file" : " files")
      if (code === 0) {
        root.notify("Restored " + what, "From snapshot #" + number + ". The previous state is saved as snapshot #" + out.trim() + ".")
        root.checked = ({})
        root.error = ""
      } else if (root.failed("Restore", err, code)) {
        root.notify("Restore failed", root.error)
      }
      root.loadList()
      root.loadChanges()
    }
  }

  HelperProc {
    id: manageProc
    property var args: []
    onDone: function(code, out, err) {
      if (code !== 0) {
        root.failed(args[0] === "create" ? "Creating snapshot" : (args[0] === "delete" ? "Deleting snapshot" : "Updating snapshot"), err, code)
      } else {
        root.error = ""
        if (args[0] === "create") {
          descField.text = ""
          root.notify("Snapshot #" + out.trim() + " created", args[2])
        }
      }
      root.loadList()
    }
  }

  HelperProc {
    id: bootedProc
    onDone: function(code, out, err) { if (code === 0) root.bootedSnapshot = Model.parseBooted(out) }
  }

  HelperProc {
    id: setupProc
    onDone: function(code, out, err) {
      if (code !== 0) root.failed("Setup", err, code)
      root.refresh()
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\u{f006f}"
    tooltipText: root.setupState !== "ok" ? "Snapshots: setup needed"
      : (root.stale ? "Snapshots: none in " + root.staleDays + " days" : "Snapshots")
    onPressed: function(b) { root.toggle() }

    Rectangle {
      visible: root.warning
      width: Style.space(6)
      height: width
      radius: width / 2
      color: root.bar.urgent
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.rightMargin: Style.space(4)
      anchors.topMargin: Style.space(4)
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.fittedContentHeight(Math.max(column.implicitHeight, root.confirmAction !== "" ? Style.space(320) : 0))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: searchField.activeFocus || descField.activeFocus || root.confirmAction !== ""
      onMoveRequested: function(dx, dy) { if (dy !== 0) root.moveCursor(dy) }
      onReturnRequested: root.enterPressed = true
      onActivateRequested: root.keyActivate()
      onCloseRequested: root.back()
      onDeleteRequested: if (root.view === "list") root.askDelete(root.rows[root.cursor])
      onTextKey: function(t) {
        if (t === "/" && root.view === "changes") searchField.forceActiveFocus()
        else if (t === "i" && root.view === "list") root.toggleImportant(root.rows[root.cursor])
        else if (t === "n" && root.view === "list") descField.forceActiveFocus()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(12)

        PanelHero {
          title: "Snapshots"
          meta: root.setupState !== "ok" ? "Setup needed"
            : !root.listLoaded ? "Loading…"
            : root.rows.length === 0 ? "No snapshots"
            : root.rows.length + " snapshots · newest " + Model.relativeDate(root.rows[0].date, root.nowMs)
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
          iconComponent: Text {
            textFormat: Text.PlainText
            text: "\u{f006f}"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.display
          }
        }

        Text {
          textFormat: Text.PlainText
          visible: root.error !== ""
          text: root.error
          color: root.bar.urgent
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
          width: parent.width
        }

        // ---------- Booted into a snapshot ----------
        BorderSurface {
          visible: root.view !== "setup" && root.bootedSnapshot >= 0
          width: parent.width
          implicitHeight: bannerContent.implicitHeight + Style.space(20)
          radius: Style.cornerRadius
          color: Util.alpha(root.bar.urgent, 0.12)
          borderSpec: Border.flat(root.bar.urgent, Style.normalBorderWidth)

          Column {
            id: bannerContent
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.margins: Style.space(10)
            spacing: Style.space(8)

            Text {
              textFormat: Text.PlainText
              width: parent.width
              wrapMode: Text.WordWrap
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
              text: root.promoteStarted
                ? "Finish the restore in the terminal, then reboot into the restored system."
                : "You're running snapshot #" + root.bootedSnapshot + ". Make it permanent?"
            }

            Row {
              spacing: Style.space(8)

              Button {
                visible: !root.promoteStarted
                text: "Make permanent"
                iconText: "\u{f0bea}"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                bordered: true
                onClicked: root.ask("promote", "Restore snapshot #" + root.bootedSnapshot
                  + " as your system? A terminal opens to run limine-snapper-restore; follow its prompts.", "Restore")
              }

              Button {
                visible: root.promoteStarted
                text: "Reboot"
                iconText: "\u{f0709}"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                bordered: true
                onClicked: root.ask("reboot", "Reboot now? Open windows will be closed.", "Reboot")
              }
            }
          }
        }

        // ---------- Setup ----------
        Column {
          visible: root.view === "setup"
          width: parent.width
          spacing: Style.space(10)

          Text {
            textFormat: Text.PlainText
            width: parent.width
            wrapMode: Text.WordWrap
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            text: root.setupState === "outdated"
              ? "The installed snapshot helpers are from another version of this plugin. Update them to keep the panel and helpers in step."
              : "Snapper needs root to read snapshots. Setup copies two small helpers and a polkit policy into root-owned system paths. You'll be asked for your password once."
          }

          Button {
            text: root.setupState === "outdated" ? "Update snapshot access" : "Set up snapshot access"
            iconText: "\u{f0483}"
            iconSpinning: setupProc.running
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            bordered: true
            hasCursor: true
            onClicked: root.runSetup()
          }
        }

        // ---------- Snapshot list ----------
        Column {
          visible: root.view === "list"
          width: parent.width
          spacing: Style.space(8)

          Row {
            width: parent.width
            spacing: Style.space(8)

            TextField {
              id: descField
              width: parent.width - createButton.width - parent.spacing
              placeholderText: "Description  ( n )"
              maximumLength: 200
              foreground: root.bar.foreground
              anchors.verticalCenter: parent.verticalCenter
              onAccepted: { root.createSnapshot(); keyCatcher.forceActiveFocus() }
              Keys.onEscapePressed: keyCatcher.forceActiveFocus()
              Keys.onDownPressed: keyCatcher.forceActiveFocus()
            }

            Button {
              id: createButton
              text: "Snapshot now"
              iconText: "\u{f0104}"
              iconSpinning: manageProc.running && manageProc.args[0] === "create"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              bordered: true
              anchors.verticalCenter: parent.verticalCenter
              onClicked: root.createSnapshot()
            }
          }

          PanelSectionHeader {
            text: "SNAPSHOTS"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          Text {
            textFormat: Text.PlainText
            visible: root.listLoaded && root.rows.length === 0
            text: "No snapshots yet."
            color: root.dim
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          ListView {
            id: listView
            width: parent.width
            height: Math.min(contentHeight, Style.space(360))
            spacing: Style.space(4)
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
            model: root.rows
            currentIndex: root.view === "list" ? root.cursor : -1
            onCurrentIndexChanged: if (currentIndex >= 0) positionViewAtIndex(currentIndex, ListView.Contain)
            delegate: SnapshotRow { }
          }

          PanelSeparator { foreground: root.bar.foreground }

          PanelSectionHeader {
            text: "RESTORE THE WHOLE SYSTEM"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            wrapMode: Text.WordWrap
            color: root.dim
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            text: "1. Reboot.\n2. In the Limine boot menu, open Snapshots and pick the one to go back to.\n3. Once it's running, open this panel and choose Make permanent."
          }

          Button {
            text: "Reboot"
            iconText: "\u{f0709}"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            bordered: true
            onClicked: root.ask("reboot", "Reboot now? Open windows will be closed. Pick a snapshot in the Limine menu.", "Reboot")
          }
        }

        // ---------- File diff ----------
        Column {
          visible: root.view === "diff"
          width: parent.width
          spacing: Style.space(8)

          Row {
            width: parent.width
            spacing: Style.space(8)

            PanelActionButton {
              id: diffBack
              iconText: "\u{f004d}"
              tooltipText: "Back"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              anchors.verticalCenter: parent.verticalCenter
              onClicked: root.back()
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width - diffBack.width - parent.spacing
              text: root.diffPath
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.subtitle
              font.bold: true
              elide: Text.ElideMiddle
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: text !== ""
            width: parent.width
            wrapMode: Text.WordWrap
            color: root.dim
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            text: diffProc.running || !root.diff ? "Loading diff…"
              : root.diff.state === "large" || root.diff.state === "binary" ? "Binary or large file, not shown."
              : root.diff.state === "empty" ? "No text differences (directory, metadata, or permissions change)."
              : ""
          }

          ListView {
            id: diffList
            width: parent.width
            height: Math.min(contentHeight, Style.space(420))
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
            model: root.diff && root.diff.state === "text" ? root.diff.lines : []
            delegate: Text {
              required property var modelData
              width: ListView.view.width
              textFormat: Text.PlainText
              text: modelData.text
              wrapMode: Text.WrapAnywhere
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              color: modelData.kind === "add" ? Color.accent
                : modelData.kind === "del" ? root.bar.urgent
                : modelData.kind === "ctx" ? root.bar.foreground
                : root.dim
            }
          }
        }

        // ---------- What changed ----------
        Column {
          visible: root.view === "changes"
          width: parent.width
          spacing: Style.space(8)

          Row {
            width: parent.width
            spacing: Style.space(8)

            PanelActionButton {
              id: backButton
              iconText: "\u{f004d}"
              tooltipText: "Back"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              anchors.verticalCenter: parent.verticalCenter
              onClicked: root.back()
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width - backButton.width - spinner.width - parent.spacing * 2
              text: root.selected ? Model.numberLabel(root.selected) + "  " + (root.selected.description || "") : ""
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.subtitle
              font.bold: true
              elide: Text.ElideRight
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              id: spinner
              textFormat: Text.PlainText
              text: "\u{f0450}"
              opacity: statusProc.running ? 1 : 0
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.icon
              anchors.verticalCenter: parent.verticalCenter
              RotationAnimation on rotation { from: 0; to: 360; duration: 900; loops: Animation.Infinite; running: statusProc.running }
            }
          }

          TextField {
            id: searchField
            width: parent.width
            placeholderText: "Search changed files  ( / )"
            text: root.filter
            foreground: root.bar.foreground
            onTextChanged: root.filter = text
            Keys.onEscapePressed: keyCatcher.forceActiveFocus()
            Keys.onDownPressed: keyCatcher.forceActiveFocus()
            Keys.onReturnPressed: keyCatcher.forceActiveFocus()
          }

          PanelSectionHeader {
            text: statusProc.running ? "COMPARING WITH NOW…"
              : root.changes.length + " CHANGES SINCE THIS SNAPSHOT"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          ListView {
            width: parent.width
            height: Math.min(contentHeight, Style.space(360))
            spacing: Style.space(2)
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
            model: root.treeItems
            currentIndex: root.view === "changes" ? root.cursor : -1
            onCurrentIndexChanged: if (currentIndex >= 0) positionViewAtIndex(currentIndex, ListView.Contain)
            delegate: TreeRow { }
          }

          Button {
            visible: root.checkedPaths.length > 0
            text: "Restore " + root.checkedPaths.length + (root.checkedPaths.length === 1 ? " file" : " files")
              + " from snapshot #" + (root.selected ? root.selected.number : "")
            iconText: "\u{f0bea}"
            iconSpinning: undoProc.running
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            bordered: true
            onClicked: root.askRestore()
          }
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          wrapMode: Text.WordWrap
          color: root.dim
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          text: root.view === "list" ? "↑↓ move · Enter open · n new · i important · x delete · Esc close"
            : root.view === "changes" ? "↑↓ move · Enter open/expand · Space select · / search · Esc back"
            : root.view === "diff" ? "↑↓ scroll · Esc back"
            : "Enter set up · Esc close"
        }
      }

      ConfirmDialog {
        id: confirmDialog
        anchors.fill: parent
        z: 10
        opened: root.confirmAction !== ""
        message: root.confirmMessage
        confirmText: root.confirmLabel
        foreground: root.bar.foreground
        fontFamily: root.bar.fontFamily
        Keys.onPressed: function(event) { event.accepted = confirmDialog.handleKey(event) }
        onCanceled: root.dismissConfirm()
        onConfirmed: root.confirmed()
      }
    }
  }

  component SnapshotRow: CursorSurface {
    id: row
    required property var modelData
    required property int index

    width: ListView.view.width
    implicitHeight: rowContent.implicitHeight + Style.spacing.rowPaddingX
    hasCursor: root.cursor === index
    foreground: root.bar.foreground

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) root.cursor = row.index
      onClicked: root.openSnapshot(row.modelData)
    }

    Row {
      id: rowContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.spacing.rowPaddingX
      anchors.rightMargin: Style.spacing.rowPaddingX
      spacing: Style.space(10)

      Text {
        id: numberText
        textFormat: Text.PlainText
        width: Style.space(52)
        text: Model.numberLabel(row.modelData)
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
        anchors.verticalCenter: parent.verticalCenter
      }

      Column {
        width: parent.width - numberText.width - starButton.width - deleteButton.width - parent.spacing * 3
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: row.modelData.description || "(no description)"
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: (Model.relativeDate(row.modelData.date, root.nowMs) + " · " + Model.typeLabel(row.modelData)).toUpperCase()
          color: root.dim
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          font.letterSpacing: 1.1
          elide: Text.ElideRight
        }
      }

      PanelActionButton {
        id: starButton
        iconText: row.modelData.important ? "\u{f04ce}" : "\u{f04d2}"
        tooltipText: row.modelData.important ? "Important: kept longer by cleanup (i)" : "Mark important (i)"
        foreground: row.modelData.important ? Color.accent : root.dim
        fontFamily: root.bar.fontFamily
        anchors.verticalCenter: parent.verticalCenter
        onClicked: root.toggleImportant(row.modelData)
      }

      PanelActionButton {
        id: deleteButton
        iconText: "\u{f01b4}"
        tooltipText: "Delete (x)"
        foreground: root.dim
        hoverColor: root.bar.urgent
        fontFamily: root.bar.fontFamily
        anchors.verticalCenter: parent.verticalCenter
        onClicked: root.askDelete(row.modelData)
      }
    }
  }

  component TreeRow: CursorSurface {
    id: item
    required property var modelData
    required property int index
    readonly property bool isGroup: modelData.kind === "group"

    width: ListView.view.width
    implicitHeight: treeContent.implicitHeight + Style.space(8)
    hasCursor: root.cursor === index
    foreground: root.bar.foreground

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) root.cursor = item.index
      onClicked: root.activate()
    }

    Row {
      id: treeContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.spacing.rowPaddingX + (item.isGroup ? 0 : Style.space(8))
      anchors.rightMargin: Style.spacing.rowPaddingX
      spacing: Style.space(8)

      Text {
        id: checkbox
        textFormat: Text.PlainText
        visible: !item.isGroup
        width: visible ? Style.space(16) : 0
        text: root.checked[item.modelData.path] ? "\u{f0132}" : "\u{f0131}"
        color: root.checked[item.modelData.path] ? Color.accent : root.dim
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.icon

        MouseArea {
          anchors.fill: parent
          anchors.margins: -Style.space(4)
          cursorShape: Qt.PointingHandCursor
          onClicked: root.toggleChecked(item.modelData.path)
        }
      }

      Text {
        id: marker
        textFormat: Text.PlainText
        width: Style.space(14)
        text: item.isGroup ? (item.modelData.collapsed ? "\u{f0142}" : "\u{f0140}")
          : (item.modelData.op === "added" ? "+" : (item.modelData.op === "removed" ? "−" : "~"))
        color: item.modelData.op === "added" ? Color.accent : (item.modelData.op === "removed" ? root.bar.urgent : root.bar.foreground)
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width - checkbox.width - marker.width - counts.width - parent.spacing * 3
        text: item.isGroup ? item.modelData.dir : item.modelData.path
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: item.isGroup
        elide: Text.ElideMiddle
      }

      Text {
        id: counts
        textFormat: Text.PlainText
        visible: item.isGroup
        width: visible ? implicitWidth : 0
        text: item.isGroup ? "+" + item.modelData.added + " −" + item.modelData.removed + " ~" + item.modelData.modified : ""
        color: root.dim
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }

  // Runs a command and reports once the exit code and both streams are in;
  // Process gives no ordering between exited and the collectors finishing.
  component HelperProc: Process {
    id: proc
    property int pending: 0
    property int code: -1
    property string out: ""
    property string err: ""
    signal done(int exitCode, string stdoutText, string stderrText)

    function start(cmd) {
      command = cmd
      code = -1
      out = ""
      err = ""
      pending = 3
      running = true
    }

    function settle() {
      pending -= 1
      if (pending === 0) done(code, out, err)
    }

    stdout: StdioCollector { waitForEnd: true; onStreamFinished: { proc.out = text; proc.settle() } }
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: { proc.err = text; proc.settle() } }
    onExited: function(exitCode) { proc.code = exitCode; proc.settle() }
  }
}
