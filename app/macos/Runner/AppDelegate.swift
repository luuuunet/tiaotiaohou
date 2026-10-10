import Cocoa
import FlutterMacOS
import Network

enum HostBridge {
  static weak var window: NSWindow?
  static var channel: FlutterMethodChannel?
  static var statusItem: NSStatusItem?
  static var quitting = false
  static var pathMonitor: NWPathMonitor?
}

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)
    renameAppMenu()
    DispatchQueue.main.async { self.renameAppMenu() }
    if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") {
      NSApp.applicationIconImage = NSImage(contentsOf: url)
    }
    NSWorkspace.shared.notificationCenter.addObserver(
      self,
      selector: #selector(onWake),
      name: NSWorkspace.didWakeNotification,
      object: nil
    )
    NSWorkspace.shared.notificationCenter.addObserver(
      self,
      selector: #selector(onWake),
      name: NSWorkspace.screensDidWakeNotification,
      object: nil
    )
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    HostBridge.showWindow()
    return true
  }

  override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if HostBridge.quitting {
      return .terminateNow
    }
    HostBridge.channel?.invokeMethod("trayQuit", arguments: nil)
    return .terminateCancel
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  @objc private func onWake() {
    HostBridge.channel?.invokeMethod("sessionUnlock", arguments: nil)
    HostBridge.channel?.invokeMethod("networkChanged", arguments: nil)
  }

  private func renameAppMenu() {
    guard let appItem = NSApp.mainMenu?.items.first else { return }
    appItem.title = "跳跳猴"
    appItem.submenu?.title = "跳跳猴"
    appItem.submenu?.items.forEach { item in
      item.title = item.title
        .replacingOccurrences(of: "APP_NAME", with: "跳跳猴")
        .replacingOccurrences(of: "rsq", with: "跳跳猴")
      if item.action == nil, item.title.contains("偏好") || item.keyEquivalent == "," {
        item.action = #selector(showWindowFromMenu)
        item.target = self
      }
    }
  }

  @objc func showWindowFromMenu() {
    HostBridge.showWindow()
  }

  @objc func toggleFromMenu() {
    HostBridge.channel?.invokeMethod("trayToggle", arguments: nil)
  }

  @objc func quitFromMenu() {
    HostBridge.channel?.invokeMethod("trayQuit", arguments: nil)
  }
}

extension HostBridge {
  static func install(window: NSWindow, channel: FlutterMethodChannel) {
    self.window = window
    self.channel = channel
    installStatusItem()
    installPathMonitor()
    if CommandLine.arguments.contains("--quiet") {
      window.orderOut(nil)
    }
  }

  static func installStatusItem() {
    if statusItem != nil { return }
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    if let button = item.button {
      button.image = statusImage()
      button.image?.isTemplate = false
      button.title = ""
      button.toolTip = "跳跳猴"
      button.imagePosition = .imageOnly
      button.imageScaling = .scaleProportionallyDown
    }
    let menu = NSMenu()
    menu.addItem(NSMenuItem(title: "显示窗口", action: #selector(AppDelegate.showWindowFromMenu), keyEquivalent: ""))
    menu.addItem(NSMenuItem(title: "连接 / 断开", action: #selector(AppDelegate.toggleFromMenu), keyEquivalent: ""))
    menu.addItem(.separator())
    menu.addItem(NSMenuItem(title: "退出跳跳猴", action: #selector(AppDelegate.quitFromMenu), keyEquivalent: "q"))
    menu.items.forEach { $0.target = NSApp.delegate }
    item.menu = menu
    statusItem = item
  }

  static func statusImage() -> NSImage {
    let size = NSSize(width: 18, height: 18)
    let source = NSApp.applicationIconImage
      ?? (Bundle.main.url(forResource: "AppIcon", withExtension: "icns").flatMap { NSImage(contentsOf: $0) })
    if let source, let copy = source.copy() as? NSImage {
      copy.size = size
      copy.isTemplate = false
      return copy
    }
    return NSImage(size: size)
  }

  static func installPathMonitor() {
    if pathMonitor != nil { return }
    let monitor = NWPathMonitor()
    monitor.pathUpdateHandler = { _ in
      DispatchQueue.main.async {
        channel?.invokeMethod("networkChanged", arguments: nil)
      }
    }
    monitor.start(queue: DispatchQueue.global(qos: .utility))
    pathMonitor = monitor
  }

  static func showWindow() {
    NSApp.activate(ignoringOtherApps: true)
    guard let window else { return }
    if window.isMiniaturized {
      window.deminiaturize(nil)
    }
    window.makeKeyAndOrderFront(nil)
  }

  static func hideToTray() {
    window?.orderOut(nil)
  }

  static func setTip(_ text: String) {
    statusItem?.button?.toolTip = text.isEmpty ? "跳跳猴" : text
  }
}
