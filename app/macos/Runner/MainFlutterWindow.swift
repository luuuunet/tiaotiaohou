import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let paper = NSColor(srgbRed: 247 / 255, green: 246 / 255, blue: 241 / 255, alpha: 1)
    flutterViewController.backgroundColor = paper
    contentViewController = flutterViewController
    backgroundColor = paper
    title = "跳跳猴"
    titleVisibility = .hidden
    titlebarAppearsTransparent = true
    isMovableByWindowBackground = false
    styleMask.remove(.resizable)
    styleMask.insert(.fullSizeContentView)
    standardWindowButton(.closeButton)?.isHidden = true
    standardWindowButton(.miniaturizeButton)?.isHidden = true
    standardWindowButton(.zoomButton)?.isHidden = true
    collectionBehavior.insert(.fullScreenAuxiliary)

    RegisterGeneratedPlugins(registry: flutterViewController)
    let channel = FlutterMethodChannel(
      name: "dev.rsq/host",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    HostBridge.install(window: self, channel: channel)

    lockSize()
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(onScreenChanged),
      name: NSWindow.didChangeScreenNotification,
      object: self
    )

    super.awakeFromNib()
  }

  override func close() {
    HostBridge.hideToTray()
  }

  @objc private func onScreenChanged() {
    lockSize(recenter: false)
  }

  override func zoom(_ sender: Any?) {}

  private func currentVisibleFrame() -> NSRect {
    screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
  }

  private func lockSize(recenter: Bool = true) {
    let vis = currentVisibleFrame()
    let width = min(1080, vis.width - 24)
    let height = min(700, vis.height - 24)
    let size = NSSize(width: width, height: height)
    minSize = size
    maxSize = size
    let origin = recenter
      ? NSPoint(x: vis.midX - width / 2, y: vis.midY - height / 2)
      : NSPoint(
        x: min(max(frame.origin.x, vis.minX), vis.maxX - width),
        y: min(max(frame.origin.y, vis.minY), vis.maxY - height)
      )
    setFrame(NSRect(origin: origin, size: size), display: true)
  }

  private func handle(_ call: FlutterMethodCall, result: FlutterResult) {
    switch call.method {
    case "drag":
      if let event = NSApp.currentEvent {
        performDrag(with: event)
      }
      result(nil)
    case "minimize":
      miniaturize(nil)
      result(nil)
    case "zoom":
      result(nil)
    case "hideToTray", "close":
      HostBridge.hideToTray()
      result(nil)
    case "showWindow":
      HostBridge.showWindow()
      result(nil)
    case "setTrayTip":
      var text = ""
      if let args = call.arguments as? [String: Any], let value = args["text"] as? String {
        text = value
      } else if let value = call.arguments as? String {
        text = value
      }
      HostBridge.setTip(text)
      result(nil)
    case "quit":
      HostBridge.quitting = true
      NSApp.terminate(nil)
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
