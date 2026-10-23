import Cocoa
import FlutterMacOS
import desktop_multi_window
import screen_retriever_macos
import window_manager

class MainFlutterWindow: NSWindow {
  private var chromeChannel: FlutterMethodChannel?
  private var deviceNameChannel: FlutterMethodChannel?
  private var trafficLightsHost: NSView?
  private var windowObservers: [NSObjectProtocol] = []
  private var alignmentScheduled = false

  override func awakeFromNib() {
    importSandboxedPreferences()
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    // Voice call windows run their own engine; give them only the plugins they use.
    FlutterMultiWindowPlugin.setOnWindowCreatedCallback { controller in
      WindowManagerPlugin.register(with: controller.registrar(forPlugin: "WindowManagerPlugin"))
      // window_manager centers the window through screen_retriever.
      ScreenRetrieverMacosPlugin.register(with: controller.registrar(forPlugin: "ScreenRetrieverMacosPlugin"))
    }

    chromeChannel = FlutterMethodChannel(name: "aicove/window_chrome", binaryMessenger: flutterViewController.engine.binaryMessenger)
    chromeChannel?.setMethodCallHandler { [weak self] call, result in
      guard call.method == "alignTrafficLights" else {
        result(FlutterMethodNotImplemented)
        return
      }
      self?.alignTrafficLightsForCurrentSize()
      result(nil)
    }

    // The computer name shown in Sharing settings, e.g. "MacBook Pro".
    deviceNameChannel = FlutterMethodChannel(name: "aicove/device_name", binaryMessenger: flutterViewController.engine.binaryMessenger)
    deviceNameChannel?.setMethodCallHandler { call, result in
      guard call.method == "read" else {
        result(FlutterMethodNotImplemented)
        return
      }
      result(Host.current().localizedName)
    }

    super.awakeFromNib()
    // AppKit can reparent and reposition standard buttons after fullscreen,
    // restoring a window, or changing screens, even without another resize.
    for name in [
      NSWindow.didEnterFullScreenNotification,
      NSWindow.didExitFullScreenNotification,
      NSWindow.didDeminiaturizeNotification,
      NSWindow.didBecomeKeyNotification,
      NSWindow.didChangeScreenNotification,
    ] {
      windowObservers.append(NotificationCenter.default.addObserver(
        forName: name, object: self, queue: .main
      ) { [weak self] _ in
        self?.scheduleTrafficLightsAlignment()
      })
    }
  }

  override func setFrame(_ frameRect: NSRect, display flag: Bool) {
    super.setFrame(frameRect, display: flag)
    // AppKit resets standard button frames during super.setFrame. Correct them
    // before returning, so a live resize never displays the intermediate layout.
    alignTrafficLightsForCurrentSize()
  }

  private func scheduleTrafficLightsAlignment() {
    guard !alignmentScheduled else { return }
    alignmentScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.alignmentScheduled = false
      self.alignTrafficLightsForCurrentSize()
    }
  }

  deinit {
    for observer in windowObservers {
      NotificationCenter.default.removeObserver(observer)
    }
  }

  private func alignTrafficLightsForCurrentSize() {
    // Flutter's post-frame request can arrive after another native resize.
    let inset: CGFloat = (contentView?.bounds.width ?? 0) >= 900 ? 12 : 0
    alignTrafficLights(inset: inset)
  }

  private func alignTrafficLights(inset: CGFloat) {
    guard let content = contentView else { return }
    let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
      .compactMap { standardWindowButton($0) }
    guard buttons.count == 3 else { return }
    let host = trafficLightsHost ?? NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 28))
    host.autoresizingMask = [.minYMargin]
    if host.superview !== content {
      content.addSubview(host, positioned: .above, relativeTo: nil)
    }
    let topOffset: CGFloat = content.bounds.width < 900 ? 34 : 42 + inset
    host.setFrameOrigin(NSPoint(x: 20 + inset, y: content.bounds.height - topOffset))
    for (index, button) in buttons.enumerated() {
      if button.superview !== host {
        button.removeFromSuperview()
        host.addSubview(button)
      }
      button.setFrameOrigin(NSPoint(x: CGFloat(index) * 20, y: (28 - button.frame.height) / 2))
    }
    trafficLightsHost = host
  }
}

/// Builds before ADR0106 ran in the App Sandbox and kept their preferences in
/// the container. Copies them once, before Flutter reads any; the Dart side
/// (AppDataMigration) moves the files and rewrites stored paths afterwards.
private func importSandboxedPreferences() {
  guard ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] == nil,
        let bundleId = Bundle.main.bundleIdentifier else { return }
  let defaults = UserDefaults.standard
  let marker = "aicove.sandboxPreferencesImported"
  if defaults.bool(forKey: marker) { return }
  let old = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Containers/\(bundleId)/Data/Library/Preferences/\(bundleId).plist")
  if FileManager.default.fileExists(atPath: old.path) {
    // Unreadable (e.g. access to the container was refused): retry next launch.
    guard let values = NSDictionary(contentsOf: old) as? [String: Any] else { return }
    let current = defaults.persistentDomain(forName: bundleId) ?? [:]
    // Preferences this build already wrote are newer than the container's.
    if !current.keys.contains(where: { $0.hasPrefix("flutter.") }) {
      for (key, value) in values where current[key] == nil {
        defaults.set(value, forKey: key)
      }
    }
  }
  defaults.set(true, forKey: marker)
}
