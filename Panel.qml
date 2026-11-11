import QtQuick
import QtQuick.Window
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Ui
import qs.Commons
import qs.Commons as Commons
import "History.js" as History

// Bell on the bar. A click opens a drawer on the reading-end side of the
// screen. Toasts leave the screen on their own; the drawer keeps them.
// Opening a row runs only a parsed argument list, never a shell line.
Panel {
  id: root
  moduleName: "pfr.notifications"
  ipcTarget: "pfr.notifications"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/omarchy/notifications"
  readonly property string drawerFont: Style.font.menuFamily
  readonly property string iconFont: bar ? bar.fontFamily : Style.font.family
  readonly property color ink: Commons.Color.notifications.text
  readonly property color dim: Qt.alpha(ink, 0.62)
  readonly property string barPos: bar ? String(bar.position || "top") : "top"

  property bool historyReady: false
  property bool liveReady: false
  property bool seenFileReady: false
  property bool seeded: false
  property bool quiet: false
  property var liveRows: []
  property var historyRows: []
  property var seenKeys: []
  property var closedKeys: []
  property bool grouped: true
  property var openGroups: []
  property var releasedMatches: ({})
  property double nowMs: Date.now()
  property int motionMs: 180
  property real reveal: 0
  property int selected: 0
  property bool cursorActive: false
  property bool focusPrimed: false

  readonly property var feed: History.merge(liveRows, historyRows)
  readonly property var entries: History.without(feed, closedKeys)
  readonly property var shown: History.rowsFor(entries, seenKeys, grouped, openGroups)
  readonly property int unread: seeded ? History.unreadCount(entries, seenKeys) : 0

  component PlainText: Text {
    textFormat: Text.PlainText
    color: root.ink
    font.family: root.drawerFont
    font.pixelSize: Style.font.body
    renderType: Text.NativeRendering
  }

  function noteHistory(text) {
    var parsed = History.parseList(text)
    if (!parsed.ok) return
    historyRows = parsed.rows
    historyReady = true
    maybeSeed()
  }

  function noteLive(text) {
    var parsed = History.parseList(text)
    if (!parsed.ok) return
    liveRows = parsed.rows
    liveReady = true
    maybeSeed()
  }

  function noteSeen(text) {
    var parsed = History.parseSeen(text)
    if (!parsed.ok) return
    seenFileReady = true
    if (!parsed.ready) {
      maybeSeed()
      return
    }
    seenKeys = parsed.keys
    closedKeys = parsed.closed
    grouped = parsed.grouped
    seeded = true
  }

  function noteQuiet(text) {
    var parsed = History.parseQuiet(text)
    if (!parsed.ok) return
    quiet = parsed.dnd
  }

  function maybeSeed() {
    if (seeded || !historyReady || !liveReady || !seenFileReady) return
    seeded = true
    saveState(History.keysOf(feed), closedKeys)
  }

  function saveState(readKeys, closed) {
    var read = History.pruneSeen(readKeys, feed)
    var gone = History.pruneSeen(closed, feed)
    seenKeys = read
    closedKeys = gone
    if (seenFile.path) seenFile.setText(History.serialiseSeen(read, gone, grouped))
  }

  function markRead(key) {
    if (!seeded || !History.validKey(key) || seenKeys.indexOf(key) >= 0) return
    saveState(seenKeys.concat([key]), closedKeys)
  }

  // Run the notification's own action: a parsed argv, or focus its app.
  // The summary and body are never part of the command.
  function openEntry(key) {
    var row = History.find(feed, key)
    if (!row) return
    markRead(key)
    if (row.argv && row.argv.length) Util.execArgv(row.argv)
    else if (row.focusApp) Util.execArgv(["omarchy-hyprland-focus-app", row.focusApp])
  }

  function toggleGroup(id) {
    var text = String(id || "")
    if (!text) return
    var cur = openGroups || []
    var next = []
    var found = false
    for (var i = 0; i < cur.length; i++) {
      if (cur[i] === text) found = true
      else next.push(cur[i])
    }
    if (!found) next.push(text)
    openGroups = next
  }

  // A pile opens and closes. One notification, or one copy inside a pile, runs.
  function activateRow(row) {
    if (!row) return
    if (!row.child && (row.count || 1) > 1) {
      toggleGroup(row.id)
      return
    }
    openEntry(row.key)
  }

  function dismissMatch(match) {
    var text = String(match || "")
    if (!text || text.length > 180) return
    Quickshell.execDetached(["omarchy-shell", "-q", "notifications", "dismiss", text])
  }

  function closeKeys(keys) {
    if (!seeded) return
    var source = keys || []
    var addRead = []
    var addClosed = []
    var matches = []
    for (var i = 0; i < source.length; i++) {
      var key = source[i]
      if (!History.validKey(key)) continue
      if (seenKeys.indexOf(key) < 0 && addRead.indexOf(key) < 0) addRead.push(key)
      if (closedKeys.indexOf(key) < 0 && addClosed.indexOf(key) < 0) addClosed.push(key)
      var row = History.find(liveRows, key)
      if (row && row.match && matches.indexOf(row.match) < 0) matches.push(row.match)
    }
    if (addClosed.length) saveState(seenKeys.concat(addRead), closedKeys.concat(addClosed))
    for (var m = 0; m < matches.length; m++) dismissMatch(matches[m])
  }

  function closeEntry(key) {
    closeKeys([key])
  }

  function closeAll() {
    if (!seeded || feed.length === 0) return
    var every = History.keysOf(feed)
    saveState(every, every)
    Quickshell.execDetached(["omarchy-shell", "-q", "notifications", "dismissAll"])
  }

  // A critical toast waits forever. Let it show, then put it away; it stays
  // in this drawer. Each summary is asked once.
  function releaseStuck() {
    var due = History.stuck(liveRows, Date.now() / 1000, 8)
    var sent = releasedMatches
    var next = ({})
    for (var i = 0; i < due.length; i++) {
      var match = due[i].match
      if (!match || next[match]) continue
      next[match] = true
      if (!sent[match]) dismissMatch(match)
    }
    releasedMatches = next
  }

  function toggleQuiet() {
    quiet = !quiet
    Quickshell.execDetached(["omarchy-shell", "-q", "notifications", "setDnd", quiet ? "on" : "off"])
  }

  function toggleGrouped() {
    grouped = !grouped
    selected = 0
    if (seeded) saveState(seenKeys, closedKeys)
  }

  function ago(ts) {
    var t = Number(ts || 0) * 1000
    if (!t) return ""
    var elapsed = Math.max(0, (nowMs - t) / 1000)
    if (elapsed < 60) return strings.t("row.justNow")
    if (elapsed < 3600) {
      var minutes = Math.round(elapsed / 60)
      return strings.tn("row.agoMinutes", minutes).arg(Commons.I18n.formatNumber(minutes))
    }
    var then = new Date(t)
    var locale = Qt.locale(Commons.I18n.formatLocale)
    if (new Date(nowMs).toDateString() === then.toDateString()) return locale.toString(then, "HH:mm")
    if (new Date(nowMs - 86400000).toDateString() === then.toDateString()) return strings.t("row.yesterday")
    return locale.toString(then, "ddd")
  }

  function openSelection() {
    if (!cursorActive || selected < 0 || selected >= shown.length) return
    activateRow(shown[selected])
  }

  function closeSelection() {
    if (!cursorActive || selected < 0 || selected >= shown.length) return
    closeKeys(shown[selected].keys)
  }

  function moveSelection(delta) {
    if (shown.length === 0) return
    cursorActive = true
    selected = Math.max(0, Math.min(shown.length - 1, selected + delta))
    entryList.positionViewAtIndex(selected, ListView.Contain)
  }

  onShownChanged: if (selected >= shown.length) selected = Math.max(0, shown.length - 1)

  // Slide, fade, and the little scale all follow this. Exits are shorter.
  Behavior on reveal {
    NumberAnimation { duration: Style.duration(root.motionMs); easing.type: Easing.OutCubic }
  }

  onOpenedChanged: {
    motionMs = opened ? 180 : 120
    reveal = opened ? 1 : 0
    if (opened) {
      focusPrimed = false
      cursorActive = false
      selected = 0
      nowMs = Date.now()
      beginFocusPrime()
      if (bar && typeof bar.requestPopout === "function") bar.requestPopout(root)
      Qt.callLater(function() { if (root.opened) keyCatcher.forceActiveFocus() })
    } else {
      focusPrimeTimer.stop()
      focusPrimed = false
      if (bar && bar.activePopout === root && typeof bar.releasePopout === "function") bar.releasePopout(root)
    }
  }

  function beginFocusPrime() {
    if (opened && drawerWindow.backingWindowVisible) focusPrimeTimer.restart()
  }

  Timer {
    id: focusPrimeTimer
    interval: 75
    onTriggered: if (root.opened) root.focusPrimed = true
  }

  Timer {
    interval: 30000
    repeat: true
    running: root.opened
    triggeredOnStart: true
    onTriggered: root.nowMs = Date.now()
  }

  Timer {
    interval: 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.releaseStuck()
  }

  Process {
    id: prepareSeen
    command: ["bash", "-c",
      "umask 077\n" +
      "dir=$1\n" +
      "file=$dir/pfr-notifications-seen.json\n" +
      "mkdir -p -- \"$dir\" || exit 1\n" +
      "if [[ -L $file ]]; then rm -f -- \"$file\"; fi\n" +
      "if [[ ! -e $file ]]; then : >\"$file\"; fi\n" +
      "chmod 600 -- \"$file\"\n",
      "pfr-notifications-seen", root.stateDir]
    onExited: function(code) { if (code === 0) seenFile.path = root.stateDir + "/pfr-notifications-seen.json" }
  }
  Component.onCompleted: prepareSeen.running = true

  FileView {
    id: historyFile
    path: root.stateDir + "/history.json"
    watchChanges: true
    printErrors: false
    onLoaded: root.noteHistory(text())
    onLoadFailed: root.noteHistory("")
    onFileChanged: reload()
  }

  FileView {
    id: liveFile
    path: root.stateDir + "/live.json"
    watchChanges: true
    printErrors: false
    onLoaded: root.noteLive(text())
    onLoadFailed: root.noteLive("")
    onFileChanged: reload()
  }

  FileView {
    id: quietFile
    path: root.stateDir + "/quiet.json"
    watchChanges: true
    printErrors: false
    onLoaded: root.noteQuiet(text())
    onLoadFailed: root.noteQuiet("")
    onFileChanged: reload()
  }

  FileView {
    id: seenFile
    path: ""
    atomicWrites: true
    watchChanges: true
    printErrors: false
    onLoaded: root.noteSeen(text())
    onLoadFailed: root.noteSeen("")
    onFileChanged: reload()
  }

  readonly property string tooltipLabel: {
    if (quiet && unread === 0) return strings.t("bar.quiet")
    if (unread > 0) return strings.tn("bar.unread", unread).arg(Commons.I18n.formatNumber(unread))
    return strings.t("bar.tooltip")
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\u{f009a}"
    dimmed: root.quiet
    tooltipText: root.tooltipLabel
    onPressed: function(b) { if (b === Qt.LeftButton) root.toggle() }
  }

  Rectangle {
    z: 2
    width: Style.space(7)
    height: width
    radius: width / 2
    color: bar ? bar.urgent : Commons.Color.urgent
    opacity: root.unread > 0 ? 1 : 0
    anchors.top: parent.top
    anchors.right: parent.right
    anchors.topMargin: Style.space(3)
    anchors.rightMargin: Style.space(2)
    Behavior on opacity { NumberAnimation { duration: Style.duration(180); easing.type: Easing.OutCubic } }
  }

  PanelWindow {
    id: drawerWindow

    readonly property var anchorWindow: button.QsWindow.window
    readonly property var hostScreen: anchorWindow ? anchorWindow.screen : null
    readonly property string barPos: root.barPos
    readonly property real screenW: screen ? screen.width : 0
    readonly property real screenH: screen ? screen.height : 0
    readonly property real barThickness: !root.bar ? 0
      : (screen && typeof root.bar.barSizeFor === "function" ? root.bar.barSizeFor(screen.name) : root.bar.barSize)
    readonly property real edgeGap: Style.gapsOut
    readonly property bool endIsLeft: Commons.I18n.rightToLeft
    readonly property real drawerWidth: Math.round(Math.min(Style.space(400), Math.max(Style.space(280), screenW - edgeGap * 2 - (barPos === "left" || barPos === "right" ? barThickness : 0))))
    readonly property real settledX: {
      if (endIsLeft) return edgeGap + (barPos === "left" ? barThickness : 0)
      return screenW - drawerWidth - edgeGap - (barPos === "right" ? barThickness : 0)
    }
    readonly property real travel: (1 - root.reveal) * (drawerWidth + edgeGap)

    function inBarRegion(px, py) {
      var strip = barThickness + edgeGap
      if (barPos === "bottom") return py >= screenH - strip
      if (barPos === "left") return px <= strip
      if (barPos === "right") return px >= screenW - strip
      return py <= strip
    }

    function forwardBarClick(px, py, button) {
      if (!root.focusPrimed || !inBarRegion(px, py)) return false
      if (button !== Qt.LeftButton && button !== Qt.RightButton && button !== Qt.MiddleButton) return false
      if (!anchorWindow || !anchorWindow.contentItem || !root.bar || !root.bar.clickTargets) return false
      var point = Qt.point(px, py)
      if (barPos === "bottom") point = Qt.point(px, py - (screenH - anchorWindow.height))
      else if (barPos === "right") point = Qt.point(px - (screenW - anchorWindow.width), py)
      var targets = root.bar.clickTargets
      for (var i = targets.length - 1; i >= 0; i--) {
        var target = targets[i]
        if (!target || !target.triggerPress || target.visible === false || target.opacity === 0) continue
        if (root.bar.targetBelongsToWindow && !root.bar.targetBelongsToWindow(target, anchorWindow)) continue
        if (Util.itemContainsPoint(target, anchorWindow.contentItem, point.x, point.y)) {
          target.triggerPress(button)
          return true
        }
      }
      return false
    }

    screen: hostScreen
    visible: hostScreen !== null && (root.opened || root.reveal > 0.001)
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "pfr-notifications"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.opened
      ? (root.focusPrimed ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.Exclusive)
      : WlrKeyboardFocus.None
    onBackingWindowVisibleChanged: {
      root.beginFocusPrime()
      if (backingWindowVisible && root.opened) keyCatcher.forceActiveFocus()
    }

    anchors { top: true; bottom: true; left: true; right: true }

    Binding {
      target: drawerWindow.contentItem
      property: "LayoutMirroring.enabled"
      value: Commons.I18n.rightToLeft
    }
    Binding {
      target: drawerWindow.contentItem
      property: "LayoutMirroring.childrenInherit"
      value: true
    }

    Rectangle {
      anchors.fill: parent
      color: Commons.Color.menu.scrim
      opacity: root.reveal
    }

    MouseArea {
      anchors.fill: parent
      enabled: root.opened
      acceptedButtons: Qt.AllButtons
      onClicked: function(mouse) {
        if (drawerWindow.forwardBarClick(mouse.x, mouse.y, mouse.button)) return
        root.close()
      }
    }

    BorderSurface {
      id: drawer
      width: drawerWindow.drawerWidth
      x: drawerWindow.endIsLeft ? drawerWindow.settledX - drawerWindow.travel : drawerWindow.settledX + drawerWindow.travel
      y: drawerWindow.edgeGap + (drawerWindow.barPos === "top" ? drawerWindow.barThickness : 0)
      height: Math.max(Style.space(200), drawerWindow.screenH - y - drawerWindow.edgeGap - (drawerWindow.barPos === "bottom" ? drawerWindow.barThickness : 0))
      radius: Style.cornerRadius
      color: Commons.Color.notifications.background
      borderSpec: Border.surfaceSpec("notifications", "border", Commons.Color.notifications.border, Math.max(1, Style.space(1)))
      padding: Style.space(16)
      clip: true
      opacity: root.reveal
      scale: 0.97 + 0.03 * root.reveal
      transformOrigin: drawerWindow.endIsLeft ? Item.Left : Item.Right

      MouseArea {
        z: -1
        anchors.fill: parent
        onClicked: function(mouse) { mouse.accepted = true }
      }

      Item {
        id: keyCatcher
        anchors.fill: parent
        anchors.topMargin: drawer.contentTopInset
        anchors.bottomMargin: drawer.contentBottomInset
        anchors.leftMargin: drawer.contentLeftInset
        anchors.rightMargin: drawer.contentRightInset
        focus: true

        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) { root.close(); event.accepted = true }
          else if (event.key === Qt.Key_Up) { root.moveSelection(-1); event.accepted = true }
          else if (event.key === Qt.Key_Down) { root.moveSelection(1); event.accepted = true }
          else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { root.openSelection(); event.accepted = true }
          else if (event.key === Qt.Key_Delete || event.key === Qt.Key_Backspace) { root.closeSelection(); event.accepted = true }
        }

        Column {
          anchors.fill: parent
          spacing: 0

          Item {
            id: header
            width: parent.width
            height: Math.max(Style.space(48), titleBlock.height)

            Item {
              id: titleBlock
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              width: titleColumn.width + Style.space(10) + groupButton.width
              height: Math.max(titleColumn.height, groupButton.height)

              Column {
                id: titleColumn
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)

                PlainText {
                  id: titleLine
                  text: strings.t("drawer.title")
                  font.pixelSize: Style.font.heading
                  font.weight: Font.DemiBold
                }
                PlainText {
                  visible: root.unread > 0
                  text: strings.tn("bar.unread", root.unread).arg(Commons.I18n.formatNumber(root.unread))
                  font.pixelSize: Style.font.caption
                  color: root.dim
                }
              }

              Rectangle {
                id: groupButton
                anchors.left: titleColumn.right
                anchors.leftMargin: Style.space(10)
                anchors.top: titleLine.top
                anchors.topMargin: Math.max(0, (titleLine.height - height) / 2)
                radius: height / 2
                color: root.grouped ? Style.selectedFillFor(root.ink, Commons.Color.accent) : "transparent"
                border.width: Math.max(1, Style.space(1))
                border.color: root.grouped ? Commons.Color.accent : Qt.alpha(root.ink, 0.28)
                implicitWidth: groupLabel.implicitWidth + Style.space(16)
                implicitHeight: groupLabel.implicitHeight + Style.space(8)
                width: implicitWidth
                height: implicitHeight

                PlainText {
                  id: groupLabel
                  anchors.centerIn: parent
                  text: root.grouped ? strings.t("drawer.grouped") : strings.t("drawer.group")
                  font.pixelSize: Style.font.caption
                  color: root.grouped ? Commons.Color.accent : root.ink
                }

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.toggleGrouped()
                }
              }
            }

            Row {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(8)

              Item {
                visible: root.entries.length > 0
                width: closeAllLabel.implicitWidth
                height: quietButton.implicitHeight

                PlainText {
                  id: closeAllLabel
                  anchors.verticalCenter: parent.verticalCenter
                  text: strings.t("drawer.closeAll")
                  font.pixelSize: Style.font.caption
                  color: closeAllMouse.containsMouse ? root.ink : root.dim

                  MouseArea {
                    id: closeAllMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.closeAll()
                  }
                }
              }

              Rectangle {
                id: quietButton
                radius: height / 2
                color: root.quiet ? Style.selectedFillFor(root.ink, Commons.Color.accent) : "transparent"
                border.width: Math.max(1, Style.space(1))
                border.color: root.quiet ? Commons.Color.accent : Qt.alpha(root.ink, 0.28)
                implicitWidth: quietLabel.implicitWidth + Style.space(16)
                implicitHeight: quietLabel.implicitHeight + Style.space(8)

                PlainText {
                  id: quietLabel
                  anchors.centerIn: parent
                  text: root.quiet ? strings.t("drawer.resume") : strings.t("drawer.quiet")
                  font.pixelSize: Style.font.caption
                  color: root.quiet ? Commons.Color.accent : root.ink
                }

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.toggleQuiet()
                }
              }
            }
          }

          Rectangle {
            width: parent.width
            height: 1
            color: Qt.alpha(root.ink, 0.12)
          }

          Item {
            width: parent.width
            height: parent.height - header.height - 1

            Column {
              visible: root.entries.length === 0
              anchors.centerIn: parent
              width: parent.width
              spacing: Style.space(8)

              PlainText {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "\u{f009a}"
                font.family: root.iconFont
                font.pixelSize: Style.font.displayLarge
                color: root.dim
              }
              PlainText {
                anchors.horizontalCenter: parent.horizontalCenter
                text: strings.t("drawer.emptyTitle")
                font.pixelSize: Style.font.title
                font.weight: Font.DemiBold
              }
              PlainText {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                text: strings.t("drawer.emptyBody")
                color: root.dim
              }
            }

            ListView {
              id: entryList
              anchors.fill: parent
              visible: root.shown.length > 0
              model: root.shown
              clip: true
              spacing: 0
              boundsBehavior: Flickable.StopAtBounds
              topMargin: Style.space(6)
              bottomMargin: Style.space(6)

              delegate: Item {
                required property var modelData
                required property int index
                width: entryList.width
                height: modelData.child ? Style.space(52) : Style.space(76)
                readonly property bool childRow: modelData.child === true
                readonly property bool pile: !childRow && (modelData.count || 1) > 1

                readonly property bool rowUnread: modelData.unread === true
                readonly property bool hot: root.cursorActive ? index === root.selected : rowMouse.containsMouse
                readonly property string iconFile: {
                  var name = String(modelData.icon || "")
                  if (!name) return ""
                  var found = Quickshell.iconPath(name, true)
                  var path = found ? String(found) : ""
                  if (!path || path.indexOf("image:") === 0 || path.indexOf("http") === 0) return ""
                  return path
                }
                readonly property string letter: {
                  var app = String(modelData.app || "")
                  return app ? app.substring(0, 1).toUpperCase() : "?"
                }

                Rectangle {
                  anchors.fill: parent
                  radius: Style.space(8)
                  color: hot ? Style.hoverFillFor(root.ink, Commons.Color.accent) : "transparent"
                }

                Rectangle {
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(8)
                  height: width
                  radius: width / 2
                  color: rowUnread ? (modelData.urgent ? Commons.Color.urgent : Commons.Color.accent) : "transparent"
                }

                Item {
                  id: thumb
                  visible: !childRow
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(24)
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(36)
                  height: width

                  Rectangle {
                    anchors.fill: parent
                    visible: iconFile === "" && !modelData.glyph
                    radius: Style.space(8)
                    color: Style.normalFillFor(root.ink, Commons.Color.accent)

                    PlainText {
                      anchors.centerIn: parent
                      text: letter
                      font.weight: Font.DemiBold
                      color: root.dim
                    }
                  }

                  PlainText {
                    anchors.centerIn: parent
                    visible: iconFile === "" && !!modelData.glyph
                    text: String(modelData.glyph || "")
                    font.family: modelData.omarchyGlyph ? "omarchy" : root.iconFont
                    font.pixelSize: Style.font.heading
                  }

                  Image {
                    anchors.fill: parent
                    anchors.margins: Style.space(4)
                    visible: iconFile !== ""
                    source: iconFile
                    fillMode: Image.PreserveAspectFit
                    asynchronous: true
                    sourceSize.width: width * Screen.devicePixelRatio
                    sourceSize.height: height * Screen.devicePixelRatio
                  }
                }

                Column {
                  id: side
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(6)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(2)
                  width: Math.max(when.implicitWidth, closeMark.implicitWidth)

                  PlainText {
                    id: when
                    width: side.width
                    horizontalAlignment: Text.AlignRight
                    text: root.ago(modelData.ts)
                    font.pixelSize: Style.font.caption
                    color: root.dim
                  }

                  PlainText {
                    id: closeMark
                    width: side.width
                    horizontalAlignment: Text.AlignRight
                    text: "×"
                    font.pixelSize: Style.font.title
                    color: closeMouse.containsMouse ? root.ink : root.dim
                  }
                }

                Column {
                  anchors.left: childRow ? parent.left : thumb.right
                  anchors.leftMargin: childRow ? Style.space(70) : Style.space(10)
                  anchors.right: side.left
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(2)

                  Item {
                    visible: !childRow
                    width: parent.width
                    height: visible ? Math.max(appName.implicitHeight, countLabel.implicitHeight) : 0

                    PlainText {
                      id: chevron
                      anchors.verticalCenter: parent.verticalCenter
                      visible: pile
                      text: modelData.open ? "\u{f078}" : "\u{f054}"
                      font.family: root.iconFont
                      font.pixelSize: Style.font.caption
                      color: root.dim
                    }

                    PlainText {
                      id: appName
                      x: chevron.visible ? chevron.implicitWidth + Style.space(4) : 0
                      width: parent.width - x - (countLabel.visible ? countLabel.implicitWidth + Style.space(8) : 0)
                      text: String(modelData.app || strings.t("row.unknownApp"))
                      font.pixelSize: Style.font.caption
                      color: root.dim
                      elide: Text.ElideRight
                      maximumLineCount: 1
                    }

                    PlainText {
                      id: countLabel
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      visible: (modelData.count || 1) > 1
                      text: Commons.I18n.formatNumber(modelData.count || 1)
                      font.pixelSize: Style.font.caption
                      font.weight: Font.DemiBold
                    }
                  }
                  PlainText {
                    width: parent.width
                    visible: !childRow && String(modelData.summary || "") !== ""
                    text: String(modelData.summary || "")
                    font.weight: rowUnread ? Font.DemiBold : Font.Normal
                    elide: Text.ElideRight
                    maximumLineCount: 1
                  }
                  PlainText {
                    width: parent.width
                    visible: childRow
                    text: String(modelData.body || modelData.summary || "")
                    font.weight: rowUnread ? Font.DemiBold : Font.Normal
                    elide: Text.ElideRight
                    maximumLineCount: 1
                  }
                  PlainText {
                    width: parent.width
                    visible: !childRow && String(modelData.body || "") !== ""
                    text: String(modelData.body || "")
                    font.pixelSize: Style.font.bodySmall
                    color: root.dim
                    elide: Text.ElideRight
                    maximumLineCount: 1
                  }
                }

                MouseArea {
                  id: rowMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onEntered: root.cursorActive = false
                  onClicked: {
                    root.cursorActive = false
                    root.selected = index
                    root.activateRow(modelData)
                  }
                }

                MouseArea {
                  id: closeMouse
                  z: 2
                  anchors.right: side.right
                  anchors.bottom: side.bottom
                  width: Style.space(28)
                  height: Style.space(28)
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.closeKeys(modelData.keys)
                }
              }
            }
          }
        }
      }
    }
  }

  Variants {
    model: root.opened ? Quickshell.screens : []

    delegate: Component {
      PanelWindow {
        required property var modelData
        screen: modelData
        visible: root.opened && !!drawerWindow.screen && modelData.name !== drawerWindow.screen.name
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.namespace: "pfr-notifications-dismiss"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        anchors { top: true; bottom: true; left: true; right: true }

        MouseArea {
          anchors.fill: parent
          acceptedButtons: Qt.AllButtons
          onPressed: root.close()
        }
      }
    }
  }
}
