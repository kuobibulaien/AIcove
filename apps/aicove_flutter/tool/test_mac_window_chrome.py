"""Check native resize geometry without launching Flutter or activating a window.

Run with Python on macOS. An optional source path allows checking a prior version.
Only Flutter startup is removed from the production window class; AppKit layout,
resize overrides, observers and alignment are exercised unchanged.
"""

from pathlib import Path
import subprocess
import sys
import tempfile

HARNESS = r'''
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let window = MainFlutterWindow(
  contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
  backing: .buffered, defer: false)
window.titlebarAppearsTransparent = true
window.titleVisibility = .hidden
window.setup()
window.alignTrafficLights(inset: 12)
var failures = 0
var checks = 0
let widths = [1000, 1100, 899, 900, 901, 420, 360, 1280]
  + Array(880...920) + Array((880...920).reversed())
for width in widths {
  for height in [700, 720, 500, 800] {
    window.setContentSize(NSSize(width: width, height: height))
    window.contentView?.layoutSubtreeIfNeeded()
    let content = window.contentView!
    let kinds: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
    // Assert before yielding the run loop: a later correction hides this bug.
    for (index, kind) in kinds.enumerated() {
      let button = window.standardWindowButton(kind)!
      let rect = content.convert(button.bounds, from: button)
      let inset: CGFloat = width >= 900 ? 12 : 0
      let expectedTop: CGFloat = width >= 900 ? 42 + inset : 34
      let top = content.bounds.height - rect.maxY
      let expectedY = expectedTop - (28 + rect.height) / 2
      let expectedX = 20 + inset + CGFloat(index) * 20
      checks += 1
      if abs(rect.minX - expectedX) > 0.1 || abs(top - expectedY) > 0.1 {
        if failures < 5 {
          print("FAIL \(width)x\(height) button=\(index) x=\(rect.minX) top=\(top)")
        }
        failures += 1
      }
    }
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.002))
  }
}
print("checks=\(checks) failures=\(failures)")
exit(failures == 0 ? 0 : 1)
'''


def main():
    default_source = Path(__file__).resolve().parents[1] / "macos/Runner/MainFlutterWindow.swift"
    source = Path(sys.argv[1] if len(sys.argv) > 1 else default_source).read_text()
    source = source.replace("import FlutterMacOS", "").replace(
        "  private var chromeChannel: FlutterMethodChannel?", ""
    )
    start = source.index("  override func awakeFromNib() {")
    end = source.index("    // AppKit", start)
    source = source[:start] + "  func setup() {\n" + source[end:]
    source = source.replace("private func alignTrafficLights", "func alignTrafficLights")
    with tempfile.TemporaryDirectory(prefix="aicove-chrome-test-") as directory:
        root = Path(directory)
        swift_source = root / "main.swift"
        swift_source.write_text(source + HARNESS)
        sdk = subprocess.check_output(
            ["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True
        ).strip()
        subprocess.run(
            ["xcrun", "swiftc", "-sdk", sdk, str(swift_source), "-o", str(root / "probe")],
            check=True,
        )
        return subprocess.run([str(root / "probe")]).returncode


if __name__ == "__main__":
    raise SystemExit(main())
