import Cocoa
import WebKit
import Network

let appName = "牛马续航小窗"
let liveURL = "https://zhangruixiang999.github.io/work-countdown/"
let syncPort: UInt16 = 47821

let cardMargin: CGFloat = 14
let fullCardSize = NSSize(width: 320, height: 206)
let compactCardSize = NSSize(width: 214, height: 62)

final class MiniWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class MiniWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class DragView: NSView {
    var onDoubleClick: (() -> Void)?
    /// 右上角按钮区：这块不拦鼠标，让点击落到下层网页的按钮上
    var passthroughRect: NSRect = .zero

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if passthroughRect != .zero {
            let local = convert(point, from: superview)
            if passthroughRect.contains(local) { return nil }
        }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, let handler = onDoubleClick {
            handler()
            return
        }
        window?.performDrag(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        if let menu = menu {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    private var window: MiniWindow!
    private var shadowView: NSView!
    private var card: NSView!
    private var effect: NSVisualEffectView!
    private var webView: MiniWebView!
    private var dragView: DragView!
    private var statusItem: NSStatusItem!
    private var statusMenu: NSMenu!
    private var showItem: NSMenuItem!
    private var compactItem: NSMenuItem!
    private var glassItem: NSMenuItem!
    private var throughItem: NSMenuItem!
    private var syncStatusItem: NSMenuItem!
    private var server: SyncServer!

    private var isGlass = false
    private var isCompact = false
    private var clickThrough = false
    private var hasState = false
    private var pendingStateJSON: String?
    private var suppressedAlertType: String?
    private var alerting = false
    private var activeSourceId: String?
    private var activeSourceFocused = false
    private var lastStateAt: TimeInterval = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupMenu()
        setupWindow()

        server = SyncServer(
            port: syncPort,
            onState: { [weak self] state in self?.applyState(state) },
            onShow: { [weak self] in self?.presentWindow() },
            onToggle: { [weak self] in
                guard let self = self else { return false }
                self.toggleWindow()
                return self.window.isVisible
            }
        )
        server.start()

        // 第一次装上时如果一直没同步，就自动把网页打开（只做一次）
        Timer.scheduledTimer(withTimeInterval: 6.0, repeats: false) { [weak self] _ in
            guard let self = self, !self.hasState else { return }
            let key = "autoOpenedWebPage"
            guard !UserDefaults.standard.bool(forKey: key) else { return }
            UserDefaults.standard.set(true, forKey: key)
            self.openWebApp()
        }

        window.orderFrontRegardless()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func setupMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu(title: appName)
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "关于 \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        let hideItem = NSMenuItem(title: "隐藏小窗", action: #selector(toggleWindow), keyEquivalent: "h")
        hideItem.target = self
        appMenu.addItem(hideItem)
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        NSApp.mainMenu = mainMenu

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            if let image = NSImage(systemSymbolName: "hourglass", accessibilityDescription: appName) {
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "牛"
            }
        }

        statusMenu = NSMenu()
        syncStatusItem = NSMenuItem(title: "等待浏览器同步…", action: nil, keyEquivalent: "")
        syncStatusItem.isEnabled = false
        statusMenu.addItem(syncStatusItem)
        statusMenu.addItem(NSMenuItem.separator())

        showItem = NSMenuItem(title: "隐藏小窗", action: #selector(toggleWindow), keyEquivalent: "")
        showItem.target = self
        statusMenu.addItem(showItem)

        compactItem = NSMenuItem(title: "收起成小条", action: #selector(toggleCompact), keyEquivalent: "")
        compactItem.target = self
        statusMenu.addItem(compactItem)

        let snapRight = NSMenuItem(title: "贴到屏幕右侧", action: #selector(snapRightEdge), keyEquivalent: "")
        snapRight.target = self
        statusMenu.addItem(snapRight)

        let resetItem = NSMenuItem(title: "回到右上角", action: #selector(resetPosition), keyEquivalent: "")
        resetItem.target = self
        statusMenu.addItem(resetItem)

        glassItem = NSMenuItem(title: "磨砂玻璃背景", action: #selector(toggleGlass), keyEquivalent: "")
        glassItem.target = self
        glassItem.state = .off
        statusMenu.addItem(glassItem)

        throughItem = NSMenuItem(title: "鼠标穿透", action: #selector(toggleThrough), keyEquivalent: "")
        throughItem.target = self
        throughItem.state = .off
        statusMenu.addItem(throughItem)

        statusMenu.addItem(NSMenuItem.separator())

        let openItem = NSMenuItem(title: "打开牛马续航网页", action: #selector(openWebApp), keyEquivalent: "")
        openItem.target = self
        statusMenu.addItem(openItem)

        statusMenu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        statusMenu.addItem(quitItem)

        statusItem.menu = statusMenu
    }

    private func setupWindow() {
        let windowSize = NSSize(width: fullCardSize.width + cardMargin * 2,
                                height: fullCardSize.height + cardMargin * 2)
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(x: screen.maxX - windowSize.width - 12,
                             y: screen.maxY - windowSize.height - 12)

        window = MiniWindow(contentRect: NSRect(origin: origin, size: windowSize),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.delegate = self

        let content = NSView(frame: NSRect(origin: .zero, size: windowSize))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.clear.cgColor
        window.contentView = content

        shadowView = NSView(frame: .zero)
        shadowView.wantsLayer = true
        shadowView.layer?.backgroundColor = NSColor.clear.cgColor
        shadowView.layer?.shadowColor = NSColor.black.cgColor
        shadowView.layer?.shadowOpacity = 0
        shadowView.layer?.shadowRadius = 18
        shadowView.layer?.shadowOffset = CGSize(width: 0, height: -5)
        content.addSubview(shadowView)

        card = NSView(frame: .zero)
        card.wantsLayer = true
        card.layer?.cornerRadius = 20
        card.layer?.masksToBounds = true
        card.layer?.borderWidth = 0
        card.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.14).cgColor
        shadowView.addSubview(card)

        effect = NSVisualEffectView(frame: .zero)
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 20
        effect.layer?.masksToBounds = true
        effect.isHidden = true
        card.addSubview(effect)

        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "miniAction")
        config.userContentController.add(self, name: "miniOpenWeb")
        webView = MiniWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        if #available(macOS 12.0, *) {
            webView.underPageBackgroundColor = .clear
        }
        webView.navigationDelegate = self
        card.addSubview(webView)

        dragView = DragView(frame: .zero)
        dragView.menu = statusMenu
        dragView.onDoubleClick = { [weak self] in self?.toggleCompact() }
        card.addSubview(dragView)

        layoutCard()
        setGlass(false)
        webView.loadHTMLString(miniHTML, baseURL: nil)

        if let saved = UserDefaults.standard.string(forKey: "windowOrigin") {
            let point = NSPointFromString(saved)
            let frame = NSRect(origin: point, size: window.frame.size)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
                window.setFrameOrigin(point)
            }
        }
    }

    private func layoutCard() {
        guard let content = window.contentView else { return }
        let cardFrame = content.bounds.insetBy(dx: cardMargin, dy: cardMargin)
        shadowView.frame = cardFrame
        shadowView.layer?.shadowPath = CGPath(roundedRect: shadowView.bounds,
                                              cornerWidth: 20, cornerHeight: 20, transform: nil)
        card.frame = NSRect(origin: .zero, size: cardFrame.size)
        effect.frame = card.bounds
        webView.frame = card.bounds
        dragView.frame = card.bounds
        updateDragArea()
    }

    private func applyState(_ state: [String: Any]) {
        let sourceId = state["sourceId"] as? String ?? "legacy"
        let focused = state["focused"] as? Bool ?? false
        let now = Date().timeIntervalSince1970
        if let active = activeSourceId, sourceId != active {
            let stale = now - lastStateAt > 5
            let promoteFromLegacy = active == "legacy" && sourceId != "legacy"
            let focusSwitch = focused && !activeSourceFocused
            if !(stale || promoteFromLegacy || focusSwitch) { return }
        }
        activeSourceId = sourceId
        activeSourceFocused = focused
        lastStateAt = now

        var state = state
        let alert = state["alert"] as? [String: Any]
        let alertType = alert?["type"] as? String
        var showAlert = alert != nil
        if let suppressed = suppressedAlertType {
            if alert == nil {
                suppressedAlertType = nil
            } else if alertType == suppressed {
                showAlert = false
            } else {
                suppressedAlertType = nil
            }
        }
        if !showAlert { state.removeValue(forKey: "alert") }

        if !hasState {
            hasState = true
            syncStatusItem.title = "已连接浏览器同步"
        }
        alerting = showAlert
        updateDragArea()
        if showAlert && clickThrough { setClickThrough(false) }

        guard let data = try? JSONSerialization.data(withJSONObject: state, options: []),
              let json = String(data: data, encoding: .utf8) else { return }
        if webView.isLoading {
            pendingStateJSON = json
        } else {
            webView.evaluateJavaScript("applyState(\(json));", completionHandler: nil)
        }
    }

    private func updateDragArea() {
        guard dragView != nil else { return }
        // 还没同步过：整张卡除了顶部一条，都留给网页（好点「打开网页版」）
        if alerting || !hasState {
            let strip: CGFloat = 34
            dragView.frame = NSRect(x: 0, y: card.bounds.height - strip,
                                    width: card.bounds.width, height: strip)
            dragView.passthroughRect = .zero
            shadowView.layer?.shadowOpacity = alerting || isGlass ? 0.28 : 0
        } else {
            dragView.frame = card.bounds
            // 右上角两颗按钮（功德 / 打开网页）交给网页自己处理点击
            dragView.passthroughRect = NSRect(x: card.bounds.width - 76,
                                              y: card.bounds.height - 38,
                                              width: 76, height: 38)
            shadowView.layer?.shadowOpacity = isGlass ? 0.28 : 0
        }
    }

    private func handleAction(_ action: String) {
        if action == "merit_add" {
            server?.setPendingAction(action, source: activeSourceId)
            return
        }
        let valid = ["water_done", "stand_done", "toilet_done", "water_skip", "stand_skip", "toilet_skip"]
        guard valid.contains(action) else { return }
        suppressedAlertType = action.components(separatedBy: "_").first
        server?.setPendingAction(action, source: activeSourceId)
        alerting = false
        updateDragArea()
        webView.evaluateJavaScript("hideAlert();", completionHandler: nil)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "miniAction", let action = message.body as? String {
            handleAction(action)
        } else if message.name == "miniOpenWeb" {
            openWebApp()
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("setGlassMode(\(isGlass));", completionHandler: nil)
        webView.evaluateJavaScript("setCompactMode(\(isCompact));", completionHandler: nil)
        if let json = pendingStateJSON {
            pendingStateJSON = nil
            webView.evaluateJavaScript("applyState(\(json));", completionHandler: nil)
        }
    }

    private func setGlass(_ on: Bool) {
        isGlass = on
        effect.isHidden = !on
        card.layer?.borderWidth = on ? 1 : 0
        shadowView.layer?.shadowOpacity = on ? 0.28 : 0
        if alerting { shadowView.layer?.shadowOpacity = 0.28 }
        glassItem.state = on ? .on : .off
        if webView != nil {
            webView.evaluateJavaScript("setGlassMode(\(on));", completionHandler: nil)
        }
    }

    @objc private func toggleCompact() {
        isCompact.toggle()
        let cardSize = isCompact ? compactCardSize : fullCardSize
        let size = NSSize(width: cardSize.width + cardMargin * 2, height: cardSize.height + cardMargin * 2)
        var frame = window.frame
        let rightEdge = frame.maxX
        frame.size = size
        frame.origin = NSPoint(x: rightEdge - size.width, y: frame.maxY - size.height)
        window.setFrame(frame, display: true, animate: true)
        layoutCard()
        compactItem.state = isCompact ? .on : .off
        webView.evaluateJavaScript("setCompactMode(\(isCompact));", completionHandler: nil)
        if isCompact { snapRightEdge() }
    }

    @objc private func snapRightEdge() {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let frame = window.frame
        let x = screen.visibleFrame.maxX - frame.width + cardMargin
        window.setFrameOrigin(NSPoint(x: x, y: frame.origin.y))
        saveOrigin()
    }

    @objc private func toggleWindow() {
        if window.isVisible {
            window.orderOut(nil)
            showItem.title = "显示小窗"
        } else {
            presentWindow()
        }
    }

    private func presentWindow() {
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(window.frame) }) {
            resetPosition()
        }
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
        window.makeKey()
        showItem.title = "隐藏小窗"
    }

    @objc private func resetPosition() {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let size = window.frame.size
        let origin = NSPoint(x: screen.visibleFrame.maxX - size.width - 12,
                             y: screen.visibleFrame.maxY - size.height - 12)
        window.setFrameOrigin(origin)
        saveOrigin()
    }

    @objc private func toggleGlass() { setGlass(!isGlass) }

    @objc private func toggleThrough() { setClickThrough(!clickThrough) }

    private func setClickThrough(_ on: Bool) {
        clickThrough = on
        window.ignoresMouseEvents = on
        throughItem.state = on ? .on : .off
    }

    @objc private func openWebApp() {
        guard let url = URL(string: liveURL) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func quitApp() { NSApp.terminate(nil) }

    private func saveOrigin() {
        UserDefaults.standard.set(NSStringFromPoint(window.frame.origin), forKey: "windowOrigin")
    }

    func windowDidMove(_ notification: Notification) { saveOrigin() }
    func windowDidResize(_ notification: Notification) { layoutCard() }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        toggleWindow()
        return false
    }
}

final class SyncServer {
    private let port: UInt16
    private let onState: ([String: Any]) -> Void
    private let onShow: () -> Void
    private let onToggle: () -> Bool
    private let queue = DispatchQueue(label: "com.niuxu.mini.sync")
    private var listener: NWListener?
    private var pendingAction: String?
    private var pendingActionSource: String?
    private let actionLock = NSLock()

    init(port: UInt16,
         onState: @escaping ([String: Any]) -> Void,
         onShow: @escaping () -> Void,
         onToggle: @escaping () -> Bool) {
        self.port = port
        self.onState = onState
        self.onShow = onShow
        self.onToggle = onToggle
    }

    func setPendingAction(_ action: String, source: String?) {
        actionLock.lock()
        pendingAction = action
        pendingActionSource = source
        actionLock.unlock()
    }

    private func takePendingAction(sourceId: String) -> String? {
        actionLock.lock()
        defer { actionLock.unlock() }
        guard let action = pendingAction else { return nil }
        if let source = pendingActionSource, !source.isEmpty, source != sourceId { return nil }
        pendingAction = nil
        pendingActionSource = nil
        return action
    }

    func start() {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        do {
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    print("[niuxu] sync listener failed: \(error)")
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            print("[niuxu] sync cannot start: \(error)")
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, buffer: Data())
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 128 * 1024) { [weak self] data, _, isComplete, error in
            guard let self = self else {
                connection.cancel()
                return
            }
            var buffer = buffer
            if let data = data { buffer.append(data) }

            if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = Data(buffer[..<headerEnd.lowerBound])
                let header = String(data: headerData, encoding: .utf8) ?? ""
                let lines = header.components(separatedBy: "\r\n")
                let requestLine = lines.first ?? ""
                var contentLength = 0
                for line in lines.dropFirst() {
                    let parts = line.split(separator: ":", maxSplits: 1)
                    if parts.count == 2, parts[0].lowercased() == "content-length" {
                        contentLength = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
                    }
                }
                let bodyStart = headerEnd.upperBound
                if buffer.count - bodyStart < contentLength {
                    self.read(connection, buffer: buffer)
                    return
                }
                let body = Data(buffer[bodyStart..<(bodyStart + contentLength)])
                self.respond(connection, requestLine: requestLine, body: body)
                return
            }

            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.read(connection, buffer: buffer)
        }
    }

    private func respond(_ connection: NWConnection, requestLine: String, body: Data) {
        let parts = requestLine.split(separator: " ")
        let method = parts.count > 0 ? String(parts[0]) : ""
        let path = parts.count > 1 ? String(parts[1]) : "/"
        var status = "200 OK"
        var payload = Data("{\"ok\":true}".utf8)

        if method == "OPTIONS" {
            status = "204 No Content"
            payload = Data()
        } else if method == "GET" && path == "/show" {
            DispatchQueue.main.async { self.onShow() }
            payload = Data("{\"ok\":true,\"visible\":true}".utf8)
        } else if method == "GET" && path == "/toggle" {
            let visible = DispatchQueue.main.sync { self.onToggle() }
            payload = Data("{\"ok\":true,\"visible\":\(visible ? "true" : "false")}".utf8)
        } else if method == "GET" && (path == "/ping" || path == "/") {
            payload = Data("{\"ok\":true,\"app\":\"niuxu-mini\"}".utf8)
        } else if method == "POST" && path == "/state" {
            if let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] {
                DispatchQueue.main.async { self.onState(object) }
                let sourceId = object["sourceId"] as? String ?? "legacy"
                if let action = takePendingAction(sourceId: sourceId) {
                    let reply: [String: Any] = ["ok": true, "action": action]
                    if let data = try? JSONSerialization.data(withJSONObject: reply) {
                        payload = data
                    }
                }
            } else {
                status = "400 Bad Request"
                payload = Data("{\"ok\":false}".utf8)
            }
        } else {
            status = "404 Not Found"
            payload = Data("{\"ok\":false}".utf8)
        }

        let headers = [
            "HTTP/1.1 \(status)",
            "Content-Type: application/json",
            "Access-Control-Allow-Origin: *",
            "Access-Control-Allow-Methods: GET, POST, OPTIONS",
            "Access-Control-Allow-Headers: content-type",
            "Access-Control-Allow-Private-Network: true",
            "Content-Length: \(payload.count)",
            "Connection: close",
            "",
            ""
        ].joined(separator: "\r\n")
        var response = Data(headers.utf8)
        response.append(payload)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}

let miniHTML = #"""
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<style>
  html, body { width: 100%; height: 100%; margin: 0; padding: 0; overflow: hidden; background: transparent; }
  body {
    font-family: -apple-system, "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", sans-serif;
    color: #fff;
    -webkit-font-smoothing: antialiased;
    -webkit-user-select: none;
    user-select: none;
    cursor: default;
  }
  .wrap { height: 100%; box-sizing: border-box; padding: 14px 16px; display: flex; flex-direction: column; }
  .full { display: flex; flex-direction: column; height: 100%; }
  .head { display: flex; align-items: center; gap: 7px; font-size: 11.5px; font-weight: 600; color: rgba(255,255,255,.78); }
  .head-status { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .head-ops { margin-left: auto; display: flex; gap: 4px; flex: none; }
  .op {
    appearance: none; border: 0; padding: 0;
    width: 24px; height: 20px;
    display: inline-flex; align-items: center; justify-content: center;
    border-radius: 7px;
    background: rgba(255,255,255,.14);
    color: #fff; font: inherit; font-size: 12px; line-height: 1;
    cursor: pointer;
    transition: background .14s ease, transform .1s ease;
  }
  .op:hover { background: rgba(255,255,255,.28); }
  .op:active { transform: scale(.88); }
  body.clear .op { background: rgba(0,0,0,.24); }
  body.clear .op:hover { background: rgba(0,0,0,.4); }
  .dot { width: 8px; height: 8px; border-radius: 50%; background: #3ddc97; box-shadow: 0 0 0 4px rgba(61,220,151,.16); flex: none; }
  .dot.idle { background: #fbbf24; box-shadow: 0 0 0 4px rgba(251,191,36,.16); }
  .label { margin-top: auto; margin-bottom: 3px; font-size: 11px; font-weight: 600; letter-spacing: .14em; color: rgba(255,255,255,.66); }
  .count {
    font-family: ui-monospace, "SF Mono", Menlo, monospace;
    font-size: 44px; line-height: 1; font-weight: 800;
    letter-spacing: -.02em; font-variant-numeric: tabular-nums;
    color: #fff; margin: 0 0 8px;
  }
  .meta { display: flex; align-items: center; gap: 8px; font-size: 11px; font-weight: 600; color: rgba(255,255,255,.78); }
  .pct { font-family: ui-monospace, Menlo, monospace; font-weight: 700; color: #3ddc97; }
  .track { flex: 1; height: 4px; border-radius: 999px; background: rgba(255,255,255,.18); overflow: hidden; font-style: normal; }
  .fill { display: block; height: 100%; width: 0%; border-radius: 999px; background: linear-gradient(90deg, #2fbf85, #3ddc97 55%, #a9f4cf); }
  .stats {
    display: flex; justify-content: space-between; gap: 6px;
    margin-top: 11px; padding-top: 9px;
    border-top: 1px solid rgba(255,255,255,.16);
    font-size: 10.5px; font-weight: 600; color: rgba(255,255,255,.76);
  }
  .stats b { color: #fff; font-size: 13px; font-weight: 800; margin: 0 1px; }
  .stats .unit { font-size: 9px; font-weight: 600; opacity: .66; margin-left: 1px; }
  .stats b.bump { display: inline-block; animation: bump .3s ease; }
  @keyframes bump {
    0% { transform: scale(1); }
    35% { transform: scale(1.45); color: #ffe08a; }
    100% { transform: scale(1); }
  }

  .mini { display: none; align-items: center; gap: 8px; width: 100%; }
  .mini-count { font-family: ui-monospace, Menlo, monospace; font-size: 21px; font-weight: 800; font-variant-numeric: tabular-nums; letter-spacing: -.01em; }
  .mini-pct { font-family: ui-monospace, Menlo, monospace; font-size: 11.5px; font-weight: 700; color: #3ddc97; margin-left: auto; }

  .hint { display: none; margin-top: 12px; }
  body.unsynced .hint { display: flex; }
  body.unsynced .meta, body.unsynced .stats { display: none; }
  body.unsynced #meritBtn { display: none; }
  .hint-btn {
    appearance: none; border: 0; border-radius: 10px;
    padding: 8px 13px; font: inherit; font-size: 12px; font-weight: 800;
    background: #fff; color: #10202a; cursor: pointer;
    box-shadow: 0 6px 16px -8px rgba(0,0,0,.6);
    transition: transform .1s ease, background .14s ease;
  }
  .hint-btn:hover { background: #eef5f1; }
  .hint-btn:active { transform: scale(.96); }
  body.compact .wrap { padding: 10px 13px; justify-content: center; }
  body.compact .full { display: none; }
  body.compact .mini { display: flex; }

  body.clear .count, body.clear .mini-count {
    text-shadow: 0 2px 10px rgba(0,0,0,.85), 0 0 2px rgba(0,0,0,.9);
  }
  body.clear .head, body.clear .label, body.clear .meta, body.clear .stats, body.clear .mini-pct {
    color: #fff;
    text-shadow:
      0 1px 0 rgba(0,0,0,.92),
      0 -1px 0 rgba(0,0,0,.92),
      1px 0 0 rgba(0,0,0,.92),
      -1px 0 0 rgba(0,0,0,.92),
      0 2px 6px rgba(0,0,0,.55);
  }
  body.clear .stats b { color: #fff; }
  body.clear .stats { border-top-color: rgba(128,128,128,.45); }

  .alert {
    position: fixed; inset: 0; display: none; flex-direction: column;
    align-items: center; justify-content: center; text-align: center;
    padding: 14px 16px; color: #fff; text-shadow: 0 1px 4px rgba(0,0,0,.3);
  }
  .alert.show { display: flex; }
  .alert.water { background: radial-gradient(circle at 50% 0%, rgba(255,255,255,.2), transparent 60%), linear-gradient(160deg, #2f6bff, #1a3fae); }
  .alert.stand { background: radial-gradient(circle at 50% 0%, rgba(255,255,255,.18), transparent 60%), linear-gradient(160deg, #e2382a, #9f1f15); }
  .alert.toilet { background: radial-gradient(circle at 50% 0%, rgba(255,255,255,.18), transparent 60%), linear-gradient(160deg, #7a5cf0, #42318f); }
  .alert-pill { font-size: 9px; letter-spacing: .16em; background: rgba(255,255,255,.16); border: 1px solid rgba(255,255,255,.22); padding: 4px 9px; border-radius: 999px; }
  .alert h2 { font-size: 22px; line-height: 1.15; font-weight: 900; letter-spacing: -.01em; margin: 10px 0 2px; }
  .alert-copy { font-size: 10.5px; line-height: 1.55; color: rgba(255,255,255,.8); margin: 4px 0 0; max-width: 260px; }
  .alert-actions { display: flex; gap: 7px; width: 100%; max-width: 250px; margin-top: 12px; }
  .alert-actions button { flex: 1; border: none; border-radius: 10px; padding: 9px 10px; font: inherit; font-size: 12px; font-weight: 700; cursor: pointer; }
  .alert-actions .primary { background: #fff; color: #1b1b1b; }
  .alert-actions .ghost { background: rgba(255,255,255,.16); color: #fff; border: 1px solid rgba(255,255,255,.22); }
  body.alerting .wrap { visibility: hidden; }
</style>
</head>
<body class="clear">
  <div class="wrap">
    <div class="full">
      <div class="head"><span class="dot idle" id="dot"></span><span class="head-status" id="status">等待浏览器同步</span><span class="head-ops"><button class="op" id="meritBtn" type="button" title="功德 +1">🧘</button><button class="op" id="webBtn" type="button" title="打开网页版">↗</button></span></div>
      <div class="label" id="label">距离下班还有</div>
      <div class="count" id="count">--:--:--</div>
      <div class="hint"><button class="hint-btn" id="hintBtn" type="button">打开网页版 →</button></div>
      <div class="meta"><span>今日进度</span><span class="pct" id="pct">0%</span><i class="track"><em class="fill" id="fill"></em></i></div>
      <div class="stats">
        <span>💧 <b id="water">0/0</b><span class="unit">ml</span></span>
        <span>🧍 <b id="stand">0</b>/<span id="standGoal">6</span></span>
        <span>🚽 <b id="toilet">0</b>/<span id="toiletGoal">2</span></span>
        <span>🧘 <b id="merit">0</b></span>
      </div>
    </div>
    <div class="mini">
      <span class="dot" id="miniDot"></span>
      <span class="mini-count" id="miniCount">--:--:--</span>
      <span class="mini-pct" id="miniPct">0%</span>
    </div>
  </div>
  <div class="alert" id="alert">
    <div class="alert-pill" id="alertPill">牛马续航</div>
    <h2 id="alertTitle"></h2>
    <p class="alert-copy" id="alertCopy"></p>
    <div class="alert-actions">
      <button class="primary" id="alertPrimary" type="button">已完成</button>
      <button class="ghost" id="alertSecondary" type="button">忽略</button>
    </div>
  </div>
<script>
  var S = {
    time: '--:--:--', label: '距离下班还有', status: '等待浏览器同步', pct: 0,
    merit: 0, water: 0, waterGoal: 8, stand: 0, standGoal: 6, toilet: 0, toiletGoal: 2,
    shiftStart: null, shiftEnd: null, statusKind: '', synced: false
  };

  function pad(n) { return n < 10 ? '0' + n : '' + n; }
  function fmt(ms) {
    ms = Math.max(0, Math.floor(ms / 1000));
    var h = Math.floor(ms / 3600);
    var m = Math.floor((ms % 3600) / 60);
    var s = ms % 60;
    return pad(h) + ':' + pad(m) + ':' + pad(s);
  }
  function setText(id, value) {
    var el = document.getElementById(id);
    if (el) el.textContent = value;
  }
  function clock() {
    var now = Date.now();
    var big = S.time, label = S.label, dot = S.statusKind === 'working' ? '' : 'idle';
    if (S.synced && S.shiftStart && S.shiftEnd) {
      if (S.statusKind === 'before') {
        big = fmt(S.shiftStart - now);
        label = '距离开始还有';
        dot = 'idle';
      } else if (S.statusKind === 'working') {
        big = fmt(S.shiftEnd - now);
        label = '距离下班还有';
        dot = '';
      } else {
        big = '00:00:00';
        label = '今天已经下班了 🎉';
        dot = '';
      }
      if (now - S.shiftEnd > 6 * 3600 * 1000) {
        big = '00:00:00';
        label = '今天已经下班了 🎉';
      }
    }
    if (!S.synced) { dot = 'idle'; label = '先在浏览器打开网页版'; }
    var unsyncedNow = !S.synced;
    if (document.body.classList.contains('unsynced') !== unsyncedNow) {
      document.body.classList.toggle('unsynced', unsyncedNow);
    }

    setText('status', S.synced ? (S.status || '上班中') : '还没同步');
    setText('label', label);
    setText('count', big);
    setText('miniCount', big);
    setText('pct', (S.pct || 0) + '%');
    setText('miniPct', (S.pct || 0) + '%');
    var fill = document.getElementById('fill');
    if (fill) fill.style.width = Math.max(0, Math.min(100, S.pct || 0)) + '%';
    var cupFallback = 250;
    var waterMl = (typeof S.waterMl === 'number') ? S.waterMl : (S.water || 0) * cupFallback;
    var waterGoalMl = (typeof S.waterGoalMl === 'number') ? S.waterGoalMl : (S.waterGoal || 8) * cupFallback;
    setText('water', waterMl + '/' + waterGoalMl);
    setText('stand', String(S.stand || 0));
    setText('standGoal', String(S.standGoal || 6));
    setText('toilet', String(S.toilet || 0));
    setText('toiletGoal', String(S.toiletGoal || 2));
    setText('merit', String((S.merit || 0) + meritPending));
    var d1 = document.getElementById('dot');
    if (d1) d1.className = 'dot ' + dot;
    var d2 = document.getElementById('miniDot');
    if (d2) d2.className = 'dot ' + dot;
  }

  var ALERT_TITLES = { water: '该喝水了', stand: '起来动动吧', toilet: '带薪拉粑时间' };
  var pendingAlertType = '';
  var meritPending = 0;

  function postToApp(name, body) {
    try {
      if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[name]) {
        window.webkit.messageHandlers[name].postMessage(body);
      }
    } catch (e) { /* ignore */ }
  }

  var meritBtn = document.getElementById('meritBtn');
  if (meritBtn) {
    meritBtn.addEventListener('click', function () {
      meritPending += 1;
      postToApp('miniAction', 'merit_add');
      var el = document.getElementById('merit');
      if (el) {
        el.classList.remove('bump');
        void el.offsetWidth;
        el.classList.add('bump');
      }
      clock();
    });
  }

  var webBtn = document.getElementById('webBtn');
  if (webBtn) {
    webBtn.addEventListener('click', function () { postToApp('miniOpenWeb', 'open'); });
  }

  var hintBtn = document.getElementById('hintBtn');
  if (hintBtn) {
    hintBtn.addEventListener('click', function () { postToApp('miniOpenWeb', 'open'); });
  }

  function showAlert(a) {
    var type = a && a.type ? a.type : 'water';
    if (!ALERT_TITLES[type]) type = 'water';
    pendingAlertType = type;
    var el = document.getElementById('alert');
    if (!el) return;
    el.className = 'alert show ' + type;
    setText('alertPill', (a.icon || '🔔') + ' 牛马续航');
    setText('alertTitle', (a.title || ALERT_TITLES[type]));
    setText('alertCopy', a.text || '');
    document.body.classList.add('alerting');
  }

  function hideAlert() {
    pendingAlertType = '';
    var el = document.getElementById('alert');
    if (el) el.className = 'alert';
    document.body.classList.remove('alerting');
  }

  function alertAction(kind) {
    if (!pendingAlertType) return;
    var action = pendingAlertType + '_' + kind;
    try {
      if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.miniAction) {
        window.webkit.messageHandlers.miniAction.postMessage(action);
      }
    } catch (e) { /* ignore */ }
    hideAlert();
  }

  document.getElementById('alertPrimary').addEventListener('click', function () { alertAction('done'); });
  document.getElementById('alertSecondary').addEventListener('click', function () { alertAction('skip'); });

  function applyState(state) {
    var prevMerit = S.merit || 0;
    var incoming = state && typeof state.merit === 'number' ? state.merit : prevMerit;
    // 小窗里点了几次功德，网页吸收几次就和本地待同步数抵消几次
    if (incoming < prevMerit) meritPending = 0;
    else if (incoming > prevMerit) meritPending = Math.max(0, meritPending - (incoming - prevMerit));
    S = state || {};
    S.synced = true;
    if (S.alert && S.alert.type) showAlert(S.alert);
    else if (pendingAlertType === '' || !S.alert) hideAlert();
    clock();
  }

  function setGlassMode(on) {
    if (on) document.body.classList.remove('clear');
    else document.body.classList.add('clear');
  }

  function setCompactMode(on) {
    document.body.classList.toggle('compact', !!on);
    clock();
  }

  setInterval(clock, 250);
  clock();
</script>
</body>
</html>
"""#

setbuf(stdout, nil)

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
