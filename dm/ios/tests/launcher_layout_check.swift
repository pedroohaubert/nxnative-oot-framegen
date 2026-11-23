// The Mac launcher window (dm/mac/Launcher.swift), run by test_launcher_storage.py: host and lay out LauncherView without creating or showing a window.
import AppKit
import SwiftUI

func checkLauncherLayout(_ model: LauncherModel, defaults: UserDefaults) -> Int {
    NSApplication.shared.setActivationPolicy(.prohibited)
    var failed = 0
    func expect(_ c: Bool, _ what: String) { print((c ? "PASS " : "FAIL ") + what); if !c { failed += 1 } }
    for size in [NSSize(width: 860, height: 500), NSSize(width: 1120, height: 640)] {
        autoreleasepool {
            let view = NSHostingView(rootView: LauncherView(m: model, done: { _ in }).defaultAppStorage(defaults))
            view.frame = NSRect(origin: .zero, size: size)
            view.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            expect(view.frame.width >= 860 && view.frame.height >= 500, "launcher view lays out at \(Int(size.width))x\(Int(size.height))")
        }
    }
    let visible = NSRect(x: -1920, y: 40, width: 1920, height: 900)
    let initial = NSRect(x: -1500, y: 540, width: 560, height: 400)
    let expanded = LauncherWindowLayout.fitted(initial, extraHeight: 300, visible: visible)
    let capped = LauncherWindowLayout.fitted(initial, extraHeight: 1200, visible: visible)
    let collapsed = LauncherWindowLayout.fitted(expanded, extraHeight: -300, visible: visible)
    expect(expanded.maxY == initial.maxY && expanded.height == 700, "expansion preserves the top edge")
    expect(capped == NSRect(x: -1500, y: 40, width: 560, height: 900), "tall content stops at the visible screen frame")
    expect(collapsed == initial, "collapse restores the content height and top edge")
    return failed
}
