import QtQuick
import QtQuick.Controls
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

  readonly property bool stale: listLoaded && Model.isStale(rows, nowMs, staleDays)
  readonly property bool warning: setupState !== "ok" || stale
  readonly property color dim: Qt.darker(root.bar.foreground, 1.5)

  function refresh() {
    nowMs = Date.now()
    installedFile.reload()
    bundledFile.reload()
    if (setupState === "ok") loadList()
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

  function failed(what, err) {
    var text = String(err || "").trim()
    error = text !== "" ? text : what + " failed"
  }

  function moveCursor(delta) {
    cursor = Math.max(0, Math.min(rows.length - 1, cursor + delta))
  }

  onSetupStateChanged: if (setupState === "ok") loadList()
  onOpenedChanged: if (opened) { refresh(); cursor = 0 }

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
      if (!parsed) { root.failed("Listing snapshots", err); return }
      root.error = ""
      root.rows = parsed
      root.listLoaded = true
      root.cursor = Math.min(root.cursor, Math.max(0, parsed.length - 1))
    }
  }

  HelperProc {
    id: setupProc
    onDone: function(code, out, err) {
      if (code !== 0) root.failed("Setup", err)
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
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) { if (dy !== 0) root.moveCursor(dy) }
      onCloseRequested: root.close()
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

        // ---------- Setup ----------
        Column {
          visible: root.setupState !== "ok"
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
          visible: root.setupState === "ok"
          width: parent.width
          spacing: Style.space(8)

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
            currentIndex: root.cursor
            onCurrentIndexChanged: if (currentIndex >= 0) positionViewAtIndex(currentIndex, ListView.Contain)
            delegate: SnapshotRow { }
          }
        }
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
        width: parent.width - numberText.width - starText.width - parent.spacing * 2
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

      Text {
        id: starText
        textFormat: Text.PlainText
        text: row.modelData.important ? "\u{f04ce}" : ""
        width: Style.space(18)
        color: Color.accent
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.icon
        anchors.verticalCenter: parent.verticalCenter
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
