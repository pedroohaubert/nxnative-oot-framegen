// Mac app launcher: compact single-column utility shown before the game starts, in the launcher's own process (launcher.c calls dm_mac_launcher before it starts the host).
// Its settings come from Resources/dm/launcher.json (dm/games/settings.py with SETTINGS_PLATFORM=mac); the model and storage live in dm/ios/Sources/LauncherSettings.swift
// (launcher.<VAR> in the app's preferences, which launcher.c reads when the window is not shown). Daily-driver settings appear under Essentials, all remaining settings plus
// microphone input, cloud saves, and reset appear under Advanced. Play writes the settings into this process's environment, which the host inherits; Quit and closing the window
// end the app without starting the game. "Show this window at launch" off skips the window unless Option is held at launch. The window follows macOS Light & Dark mode and never
// takes focus by itself: an app opened in the background (open -g) stays behind until the player switches to it.
import AppKit
import AVFAudio
import CoreAudio
import QuartzCore
import SwiftUI

private func info(_ key: String) -> String? { Bundle.main.object(forInfoDictionaryKey: key) as? String }

/// The host's comparison of the two saves (dm/host/save_sync.c). This launcher links save_sync.o but imports no C header (pack_app.py builds it with swiftc and no bridging
/// header), so the symbol is declared here.
@_silgen_name("save_sync_report")
private func save_sync_report(_ save: UnsafePointer<CChar>, _ title: UnsafePointer<CChar>, _ folder: UnsafePointer<CChar>?, _ waitMs: Int32,
                              _ out: UnsafeMutablePointer<CChar>, _ n: Int) -> Int32

/// Cloud saves before Play: this Mac's save against the cloud's (SaveSyncReport, shared with the iPhone launcher), and the question it needs, as alerts.
/// It runs with the window's Play and, with the window off, before dmMacLauncher returns; DM_LAUNCHER=0 asks nothing (the host takes the newer save).
enum SaveCheck {
    enum Outcome { case play(String?), retry, cancel }

    /// The folder as launcher.c will pass it (cloud_saves_folder): DM_SAVE_SYNC from the launch environment or an env file, else the window's choice; "" or "0" = off.
    static func effectiveFolder(defaults: UserDefaults = .standard) -> String {
        getenv("DM_SAVE_SYNC").map { String(cString: $0) } ?? (defaults.string(forKey: "cloudSaves.folder") ?? "")
    }

    /// Blocks while the cloud's file comes (SaveSyncReport.waitMs at most): call it off the main thread. nil: no report (sync is then left to the host as before)
    static func report(folder: String? = nil) -> SaveSyncReport? {
        // getenv, not ProcessInfo.environment: launcher.c sets DM_SAVE and applies the env files in this process before the window
        guard let save = getenv("DM_SAVE") else { fputs("launcher: save sync: no DM_SAVE\n", stderr); return nil }
        guard let id = info("DMTitleID"), !id.isEmpty else { fputs("launcher: save sync: no DMTitleID\n", stderr); return nil }
        let folder = folder ?? effectiveFolder()
        var buf = [CChar](repeating: 0, count: 1024)
        let r = (folder.isEmpty ? "0" : folder).withCString { save_sync_report(save, id, $0, SaveSyncReport.waitMs, &buf, buf.count) }
        let line = String(cString: buf)
        guard r == 0 else { fputs("launcher: save sync: no report on \(String(cString: save))\n", stderr); return nil }
        fputs("launcher: save sync: \(line)\n", stderr)
        return SaveSyncReport(line: line)
    }

    /// The question the report needs, as a modal alert; `cancel` names the way back ("Cancel" to the window, "Quit" without one)
    static func ask(_ r: SaveSyncReport?, cancel: String) -> Outcome {
        switch SaveSyncReport.step(r) {
        case .play(let choice): return .play(choice)
        case .choose:
            guard let r else { return .play(nil) }
            let a = NSAlert()
            a.messageText = SaveSyncReport.chooseTitle
            a.informativeText = r.chooseMessage(here: "Mac")
            a.alertStyle = .warning
            a.addButton(withTitle: r.localLabel(here: "Mac"))
            a.addButton(withTitle: r.cloudLabel)
            a.addButton(withTitle: cancel)
            a.buttons[0].keyEquivalent = ""   // no default: Return must not pick a save (the newer is not always the one to keep)
            a.buttons[2].keyEquivalent = "\u{1b}"
            switch a.runModal() {
            case .alertFirstButtonReturn: return .play(r.localChoice)
            case .alertSecondButtonReturn: return .play(r.cloudChoice)
            default: return .cancel
            }
        case .missing:
            guard let r else { return .play(nil) }
            let a = NSAlert()
            a.messageText = SaveSyncReport.missingTitle
            a.informativeText = r.missingMessage(here: "Mac")
            a.alertStyle = .warning
            a.addButton(withTitle: "Try again")
            a.addButton(withTitle: "Play without sending")
            a.addButton(withTitle: r.sendLabel(here: "Mac"))
            a.addButton(withTitle: cancel)
            a.buttons[2].hasDestructiveAction = true
            a.buttons[3].keyEquivalent = "\u{1b}"
            switch a.runModal() {
            case .alertFirstButtonReturn: return .retry
            case .alertSecondButtonReturn: return .play("offline")   // this Mac's save, not sent: the next start compares again
            case .alertThirdButtonReturn: return .play(r.localChoice)   // local:none
            default: return .cancel
            }
        case .unreadable:
            let a = NSAlert()
            a.messageText = SaveSyncReport.unreadableTitle
            a.informativeText = r?.unreadableMessage(here: "Mac") ?? ""
            a.addButton(withTitle: "Play this Mac's save")
            a.addButton(withTitle: "Try again")
            a.addButton(withTitle: cancel)
            a.buttons[2].keyEquivalent = "\u{1b}"
            switch a.runModal() {
            case .alertFirstButtonReturn: return .play("offline")   // the mount does not wait for the cloud again
            case .alertSecondButtonReturn: return .retry
            default: return .cancel
            }
        }
    }

    static func apply(_ choice: String?) {
        guard let choice else { return }
        setenv("DM_SAVE_SYNC_CHOICE", choice, 1)
        fputs("launcher: DM_SAVE_SYNC_CHOICE=\(choice)\n", stderr)
    }

    /// With the window off: the check and its question before the game, the app in front only while it asks. false: the player quit
    static func withoutWindow(defaults: UserDefaults = .standard) -> Bool {
        let folder = effectiveFolder(defaults: defaults)
        guard SaveSyncReport.syncEnabled(folder) else { return true }
        final class Box: @unchecked Sendable { let lock = NSLock(); var report: SaveSyncReport?; var waiting = false }
        let app = NSApplication.shared
        defer { app.setActivationPolicy(.prohibited) }
        while true {
            let box = Box(), sem = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .userInitiated).async {
                let r = report(folder: folder)
                box.lock.lock(); box.report = r; box.lock.unlock()
                sem.signal()
                DispatchQueue.main.async { if box.waiting { app.abortModal() } }   // runs inside the waiting alert's modal loop, if there is one
            }
            if sem.wait(timeout: .now() + 0.5) == .timedOut {   // a cloud file to download: say so, and let the player go on without it
                app.setActivationPolicy(.regular); app.activate(ignoringOtherApps: true)
                let a = NSAlert()
                a.messageText = "Checking cloud save…"
                a.informativeText = "Waiting for iCloud to deliver this game's save."
                a.addButton(withTitle: "Play without it")
                a.addButton(withTitle: "Quit")
                box.waiting = true
                let answer = a.runModal()
                box.waiting = false
                if answer == .alertFirstButtonReturn { apply("offline"); return true }
                if answer == .alertSecondButtonReturn { return false }
                sem.wait()   // aborted: the report is in
            }
            box.lock.lock(); let r = box.report; box.lock.unlock()
            if case .play(let choice) = SaveSyncReport.step(r) { apply(choice); return true }
            app.setActivationPolicy(.regular); app.activate(ignoringOtherApps: true)
            switch ask(r, cancel: "Quit") {
            case .play(let choice): apply(choice); return true
            case .retry: continue
            case .cancel: return false
            }
        }
    }
}

// MARK: - Tactile Design tokens (warm 12-step sand scale, Light & Dark)

private struct TactilePalette {
    let isDark: Bool

    init(_ scheme: ColorScheme) { self.isDark = (scheme == .dark) }

    private static func hex(_ value: UInt32) -> Color {
        Color(
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0
        )
    }

    var ground: Color { isDark ? Self.hex(0x080807) : Self.hex(0xF9F9F8) }
    var card: Color { isDark ? Self.hex(0x191918) : Color.white }
    var well: Color { isDark ? Self.hex(0x222221) : Self.hex(0xF1F0EF) }
    var controlFill: Color { isDark ? Self.hex(0x2A2A28) : Color.white }
    var controlHover: Color { isDark ? Self.hex(0x31312E) : Self.hex(0xF9F9F8) }
    var ghostHover: Color { isDark ? Self.hex(0x222221) : Self.hex(0xF1F0EF) }

    var ink1: Color { isDark ? Self.hex(0x111110) : Self.hex(0xFDFDFC) }
    var ink3: Color { isDark ? Self.hex(0x222221) : Self.hex(0xF1F0EF) }
    var ink5: Color { isDark ? Self.hex(0x31312E) : Self.hex(0xE2E1DE) }
    var ink6: Color { isDark ? Self.hex(0x3B3A37) : Self.hex(0xDAD9D6) }
    var ink7: Color { isDark ? Self.hex(0x494844) : Self.hex(0xCFCECA) }
    var ink9: Color { isDark ? Self.hex(0x6F6D66) : Self.hex(0x8D8D86) }
    var ink10: Color { isDark ? Self.hex(0x7C7B74) : Self.hex(0x82827C) }
    var ink11: Color { isDark ? Self.hex(0xB5B3AD) : Self.hex(0x63635E) }
    var ink12: Color { isDark ? Self.hex(0xEEEEEC) : Self.hex(0x21201C) }

    var line: Color { isDark ? ink5 : ink6 }
    var cardRing: Color { isDark ? ink6 : ink12.opacity(0.08) }
    var controlRing: Color { isDark ? ink7 : ink12.opacity(0.09) }
    var ringWidth: CGFloat { isDark ? 0.5 : 1.0 }

    var primaryBg: Color { ink12 }
    var primaryFg: Color { ink1 }
    var switchOn: Color { Self.hex(0x30A46C) }
    var switchOff: Color { isDark ? Self.hex(0x343434) : ink7 }
    var statusGreen: Color { isDark ? Self.hex(0x3DD68C) : Self.hex(0x2B9A66) }
}

private enum TactileMetrics {
    static let windowWidth: CGFloat = 520
    static let windowHeight: CGFloat = 564
    static let minWidth: CGFloat = 480
    static let minHeight: CGFloat = 480
    static let cardRadius: CGFloat = 10
    static let controlRadius: CGFloat = 6
    static let hairline: CGFloat = 0.5
}

// MARK: - Tactile primitives

private struct TactileButtonStyle: ButtonStyle {
    enum Role { case primary, secondary, ghost }

    let role: Role
    let compact: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false

    init(_ role: Role, compact: Bool = false) {
        self.role = role
        self.compact = compact
    }

    func makeBody(configuration: Configuration) -> some View {
        let p = TactilePalette(scheme)
        let height: CGFloat = compact ? 28 : 32
        let bg: Color = {
            switch role {
            case .primary:
                return p.primaryBg.opacity(hovered && enabled ? 0.90 : 1.0)
            case .secondary:
                return hovered && enabled ? p.controlHover : p.controlFill
            case .ghost:
                return hovered && enabled ? p.ghostHover : .clear
            }
        }()
        let fg: Color = {
            switch role {
            case .primary: return p.primaryFg
            case .secondary: return p.ink12
            case .ghost: return hovered && enabled ? p.ink12 : p.ink11
            }
        }()

        configuration.label
            .font(.system(size: compact ? 12.5 : 13, weight: .regular))
            .tracking(-0.13)
            .foregroundStyle(fg)
            .frame(height: height)
            .padding(.horizontal, compact ? 10 : 12)
            .background(bg, in: RoundedRectangle(cornerRadius: TactileMetrics.controlRadius, style: .continuous))
            .overlay {
                if role == .secondary {
                    RoundedRectangle(cornerRadius: TactileMetrics.controlRadius, style: .continuous)
                        .strokeBorder(p.controlRing, lineWidth: p.ringWidth)
                } else if role == .primary {
                    RoundedRectangle(cornerRadius: TactileMetrics.controlRadius, style: .continuous)
                        .strokeBorder(p.primaryBg, lineWidth: 0.5)
                }
            }
            .shadow(
                color: role == .ghost ? .clear : (p.isDark ? Color.black.opacity(0.45) : p.ink12.opacity(role == .primary ? 0.14 : 0.10)),
                radius: p.isDark ? 2 : 1.5,
                x: 0,
                y: 1
            )
            .opacity(enabled ? 1.0 : 0.45)
            .scaleEffect(configuration.isPressed && enabled ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.15), value: hovered)
            .onHover { hovered = $0 }
    }
}

private struct TactileSwitch: View {
    @Binding var isOn: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let p = TactilePalette(scheme)
        Button {
            guard enabled else { return }
            if reduceMotion {
                isOn.toggle()
            } else {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.80)) {
                    isOn.toggle()
                }
            }
        } label: {
            HStack(spacing: 0) {
                if isOn { Spacer(minLength: 0) }
                Circle()
                    .fill(Color.white)
                    .frame(width: 18, height: 18)
                    .overlay(
                        Circle().strokeBorder(p.isDark ? Color.black.opacity(0.28) : p.ink12.opacity(0.08), lineWidth: 0.5)
                    )
                    .shadow(color: p.isDark ? Color.black.opacity(0.5) : p.ink12.opacity(0.16), radius: 1.5, x: 0, y: 1)
                if !isOn { Spacer(minLength: 0) }
            }
            .padding(3)
            .frame(width: 44, height: 24)
            .background(isOn ? p.switchOn : p.switchOff, in: Capsule())
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isOn)
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1.0 : 0.55)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

private struct TactileCheckbox: View {
    let title: String
    @Binding var isOn: Bool
    @Environment(\.colorScheme) private var scheme
    @State private var hovered = false

    var body: some View {
        let p = TactilePalette(scheme)
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 7) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(isOn ? p.ink12 : (hovered ? p.well : p.controlFill))
                        .frame(width: 15, height: 15)
                        .overlay {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(isOn ? p.ink12 : p.ink7, lineWidth: isOn ? 0 : 1.25)
                        }
                    if isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(p.ink1)
                    }
                }
                Text(title)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(hovered ? p.ink12 : p.ink11)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

private struct SegmentShape: InsettableShape {
    let pill: Bool
    let radius: CGFloat
    var insetAmount: CGFloat = 0

    func inset(by amount: CGFloat) -> SegmentShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }

    func path(in rect: CGRect) -> Path {
        let insetRect = rect.insetBy(dx: insetAmount, dy: insetAmount)
        if pill {
            return Capsule(style: .circular).path(in: insetRect)
        }
        return RoundedRectangle(cornerRadius: max(radius - insetAmount, 0), style: .continuous).path(in: insetRect)
    }
}

private struct TactilePillSegment<T: Hashable>: View {
    let items: [(T, String)]
    @Binding var selection: T
    let pillShape: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var namespace
    @State private var hovered: T?

    init(items: [(T, String)], selection: Binding<T>, pillShape: Bool = true) {
        self.items = items
        self._selection = selection
        self.pillShape = pillShape
    }

    var body: some View {
        let p = TactilePalette(scheme)
        let inset: CGFloat = 3
        let itemHeight: CGFloat = pillShape ? 26 : 24
        let trackShape = SegmentShape(pill: pillShape, radius: 7)
        let itemShape = SegmentShape(pill: pillShape, radius: 5)

        HStack(spacing: 2) {
            ForEach(items, id: \.0) { value, label in
                let active = (selection == value)
                Button {
                    guard enabled, selection != value else { return }
                    if reduceMotion {
                        withAnimation(.easeOut(duration: 0.15)) { selection = value }
                    } else {
                        withAnimation(.spring(response: 0.30, dampingFraction: 0.86)) { selection = value }
                    }
                } label: {
                    Text(label)
                        .font(.system(size: pillShape ? 12.5 : 12, weight: .regular))
                        .tracking(-0.12)
                        .monospacedDigit()
                        .foregroundStyle(active ? p.ink12 : (hovered == value ? p.ink12 : p.ink11))
                        .padding(.horizontal, pillShape ? 11 : 9)
                        .frame(height: itemHeight)
                        .background {
                            if active {
                                itemShape
                                    .fill(p.controlFill)
                                    .overlay {
                                        itemShape
                                            .strokeBorder(p.controlRing, lineWidth: p.ringWidth)
                                    }
                                    .shadow(
                                        color: p.isDark ? Color.black.opacity(0.45) : p.ink12.opacity(0.10),
                                        radius: p.isDark ? 2 : 1.5,
                                        x: 0,
                                        y: 1
                                    )
                                    .matchedGeometryEffect(id: "active-pill", in: namespace)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { isInside in hovered = isInside ? value : (hovered == value ? nil : hovered) }
            }
        }
        .padding(inset)
        .background(p.well, in: trackShape)
        .clipShape(trackShape)
        .opacity(enabled ? 1.0 : 0.55)
    }
}

private struct TactileMenuPicker: View {
    let options: [[String]]
    @Binding var selection: String
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false

    private var currentLabel: String {
        options.first(where: { $0[0] == selection })?[1] ?? selection
    }

    var body: some View {
        let p = TactilePalette(scheme)
        Menu {
            ForEach(options, id: \.[0]) { option in
                Button(option[1]) { selection = option[0] }
            }
        } label: {
            HStack(spacing: 6) {
                Text(currentLabel)
                    .font(.system(size: 12.5, weight: .regular))
                    .foregroundStyle(p.ink12)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(p.ink10)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(hovered && enabled ? p.controlHover : p.controlFill, in: RoundedRectangle(cornerRadius: TactileMetrics.controlRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: TactileMetrics.controlRadius, style: .continuous)
                    .strokeBorder(p.controlRing, lineWidth: p.ringWidth)
            }
            .shadow(color: p.isDark ? Color.black.opacity(0.45) : p.ink12.opacity(0.09), radius: p.isDark ? 2 : 1.5, x: 0, y: 1)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .opacity(enabled ? 1.0 : 0.55)
        .onHover { hovered = $0 }
    }
}

private struct TactileSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let label: String
    let valueLabel: String
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var enabled

    private var fraction: CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return CGFloat(min(max((value - range.lowerBound) / span, 0), 1))
    }

    private func snapped(_ raw: Double) -> Double {
        let clamped = min(max(raw, range.lowerBound), range.upperBound)
        guard step > 0 else { return clamped }
        let steps = ((clamped - range.lowerBound) / step).rounded()
        return min(max(range.lowerBound + steps * step, range.lowerBound), range.upperBound)
    }

    var body: some View {
        let p = TactilePalette(scheme)
        GeometryReader { geo in
            let thumbSize: CGFloat = 16
            let trackWidth = max(geo.size.width - thumbSize, 1)
            let x = fraction * trackWidth
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(p.well)
                    .frame(height: 4)
                Capsule()
                    .fill(p.ink12)
                    .frame(width: max(x + thumbSize / 2, 4), height: 4)
                Circle()
                    .fill(Color.white)
                    .frame(width: thumbSize, height: thumbSize)
                    .overlay(
                        Circle().strokeBorder(p.isDark ? p.ink7 : p.ink12.opacity(0.14), lineWidth: p.isDark ? 0.5 : 1.0)
                    )
                    .shadow(color: p.isDark ? Color.black.opacity(0.55) : p.ink12.opacity(0.18), radius: 2, x: 0, y: 1)
                    .offset(x: x)
            }
            .frame(height: 20)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        guard enabled else { return }
                        let f = min(max((drag.location.x - thumbSize / 2) / trackWidth, 0), 1)
                        let next = snapped(range.lowerBound + Double(f) * (range.upperBound - range.lowerBound))
                        if abs(next - value) > 1e-6 { value = next }
                    }
            )
        }
        .frame(height: 20)
        .opacity(enabled ? 1.0 : 0.55)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(valueLabel)
        .accessibilityAdjustableAction { direction in
            guard enabled else { return }
            switch direction {
            case .increment: value = snapped(value + step)
            case .decrement: value = snapped(value - step)
            @unknown default: break
            }
        }
    }
}

// MARK: - Launcher view (Direction A: compact single-column utility)

enum LauncherTab: String, Hashable {
    case essentials
    case advanced
}

struct LauncherView: View {
    @ObservedObject var m: LauncherModel
    let done: (Bool) -> Void
    private let titleOverride: String?
    private let versionOverride: String?
    private let iconOverride: NSImage?
    private let lastPlayedOverride: String?

    @AppStorage("window.show") private var show = true
    @AppStorage("cloudSaves.folder") private var cloudFolder = ""
    @State private var tab: LauncherTab
    @State private var checking = false
    @State private var check = 0   // which Play the running check is for: one the player went on from without it is dropped
    @State private var lastPlayed: String?
    @Environment(\.colorScheme) private var scheme

    // Preferred daily-driver settings for Essentials (5-6 rows max, general across games).
    private static let preferredEssentials = [
        "DM_FPS_TARGET",
        "DM_RENDER_SCALE",
        "DM_FULLSCREEN",
        "DM_OPMODE",
        "DM_DYNAMIC_RESOLUTION",
        "DM_NVN_TEX_MIP_SKIP",
    ]

    init(
        m: LauncherModel,
        done: @escaping (Bool) -> Void,
        initialTab: LauncherTab = .essentials,
        titleOverride: String? = nil,
        versionOverride: String? = nil,
        iconOverride: NSImage? = nil,
        lastPlayedOverride: String? = nil
    ) {
        self.m = m
        self.done = done
        self._tab = State(initialValue: initialTab)
        self.titleOverride = titleOverride
        self.versionOverride = versionOverride
        self.iconOverride = iconOverride
        self.lastPlayedOverride = lastPlayedOverride
        self._lastPlayed = State(initialValue: lastPlayedOverride)
    }

    private var essentialSettings: [Setting] {
        var picked: [Setting] = []
        var seen = Set<String>()
        for env in Self.preferredEssentials {
            if let s = m.settings.first(where: { $0.env == env && m.visible($0) }) {
                picked.append(s)
                seen.insert(s.env)
            }
        }
        if picked.count < 6 {
            for s in m.settings where s.basic && m.visible(s) && !seen.contains(s.env) {
                picked.append(s)
                seen.insert(s.env)
                if picked.count == 6 { break }
            }
        }
        return picked
    }

    private var essentialEnvs: Set<String> {
        Set(essentialSettings.map(\.env))
    }

    private var advancedSections: [(String, [Setting])] {
        let excluded = essentialEnvs
        var order: [String] = []
        var grouped: [String: [Setting]] = [:]
        for s in m.settings where !excluded.contains(s.env) && (m.visible(s) || s.env == "DM_FRAMEGEN") {
            let key = s.sectionTitle
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(s)
        }
        return order.compactMap { title in
            guard let rows = grouped[title], !rows.isEmpty else { return nil }
            return (title, rows)
        }
    }

    private var displayTitle: String {
        if let titleOverride, !titleOverride.isEmpty { return titleOverride }
        if let envTitle = ProcessInfo.processInfo.environment["DM_LAUNCHER_TITLE"], !envTitle.isEmpty { return envTitle }
        return info("CFBundleDisplayName") ?? info("CFBundleName") ?? "Game"
    }

    private var displayVersion: String? {
        let raw = versionOverride ?? info("CFBundleShortVersionString")
        guard let v = raw, !v.isEmpty else { return nil }
        return "v\(v)"
    }

    private var appIcon: NSImage? {
        if let iconOverride { return iconOverride }
        return NSApp?.applicationIconImage
    }

    private var cloudActive: Bool {
        let env = getenv("DM_SAVE_SYNC").map { String(cString: $0) }
        return SaveSyncReport.syncEnabled(env ?? cloudFolder)
    }

    var body: some View {
        let p = TactilePalette(scheme)
        VStack(alignment: .leading, spacing: 0) {
            header(p)
                .padding(.top, 38)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)

            mainCard(p)
                .padding(.horizontal, 20)
                .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(p.ground)
        .ignoresSafeArea(.container, edges: .top)
        .background(alignment: .topLeading) {
            Group {
                Button("") {
                    tab = (tab == .essentials) ? .advanced : .essentials
                }
                .keyboardShortcut(",", modifiers: .command)
                if tab == .advanced {
                    Button("") { tab = .essentials }
                        .keyboardShortcut(.cancelAction)
                }
            }
            .opacity(0)
            .allowsHitTesting(false)
        }
        .task {
            if lastPlayedOverride == nil {
                lastPlayed = macLastPlayed()
            }
        }
    }

    private func header(_ p: TactilePalette) -> some View {
        HStack(spacing: 12) {
            if let icon = appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(p.cardRing, lineWidth: 0.5)
                    )
                    .shadow(color: p.isDark ? Color.black.opacity(0.45) : p.ink12.opacity(0.10), radius: 2, x: 0, y: 1)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(displayTitle)
                    .font(.system(size: 16, weight: .medium))
                    .tracking(-0.2)
                    .foregroundStyle(p.ink12)
                    .lineLimit(1)
                    .truncationMode(.tail)

                metaLine(p)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func metaLine(_ p: TactilePalette) -> some View {
        let parts = [displayVersion, lastPlayed].compactMap { $0 }
        if !parts.isEmpty || cloudActive {
            HStack(spacing: 6) {
                if !parts.isEmpty {
                    Text(parts.joined(separator: " · "))
                        .font(.system(size: 12, weight: .regular))
                        .monospacedDigit()
                        .foregroundStyle(p.ink11)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if cloudActive {
                    if !parts.isEmpty {
                        Text("·")
                            .font(.system(size: 12))
                            .foregroundStyle(p.ink10)
                    }
                    HStack(spacing: 5) {
                        Circle()
                            .fill(p.statusGreen)
                            .frame(width: 7, height: 7)
                        Text("Cloud saves on")
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(p.ink11)
                    }
                    .fixedSize()
                }
            }
        }
    }

    private func mainCard(_ p: TactilePalette) -> some View {
        VStack(spacing: 0) {
            cardTopBar(p)
                .background(p.card)
            Rectangle().fill(p.line).frame(height: TactileMetrics.hairline)
            cardContent(p)
                .clipped()
            cardFooter(p)
                .background(p.card)
                .overlay(alignment: .top) {
                    Rectangle().fill(p.line).frame(height: TactileMetrics.hairline)
                }
        }
        .background(p.card, in: RoundedRectangle(cornerRadius: TactileMetrics.cardRadius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: TactileMetrics.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: TactileMetrics.cardRadius, style: .continuous)
                .strokeBorder(p.cardRing, lineWidth: p.ringWidth)
        }
        .shadow(color: p.isDark ? Color.black.opacity(0.50) : p.ink12.opacity(0.08), radius: p.isDark ? 2 : 1.5, x: 0, y: 1)
        .shadow(color: p.isDark ? Color.black.opacity(0.35) : p.ink12.opacity(0.05), radius: p.isDark ? 5 : 4, x: 0, y: 3)
    }

    private func cardTopBar(_ p: TactilePalette) -> some View {
        HStack(spacing: 10) {
            TactilePillSegment(
                items: [(.essentials, "Essentials"), (.advanced, "Advanced")],
                selection: $tab,
                pillShape: true
            )
            Spacer(minLength: 8)
            if m.changed {
                Text("Modified")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(p.ink11)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private func cardContent(_ p: TactilePalette) -> some View {
        ScrollView(.vertical, showsIndicators: true) {
            if tab == .essentials {
                essentialsBody(p)
            } else {
                advancedBody(p)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func essentialsBody(_ p: TactilePalette) -> some View {
        let rows = essentialSettings
        return VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.env) { index, setting in
                TactileSettingRow(s: setting, m: m, showDescription: false)
                    .padding(.vertical, 11)
                if index < rows.count - 1 {
                    Rectangle().fill(p.line).frame(height: TactileMetrics.hairline)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private func advancedBody(_ p: TactilePalette) -> some View {
        let sections = advancedSections
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(sections.enumerated()), id: \.element.0) { sIndex, section in
                VStack(alignment: .leading, spacing: 0) {
                    Text(section.0)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(p.ink11)
                        .padding(.top, sIndex == 0 ? 12 : 16)
                        .padding(.bottom, 4)

                    ForEach(Array(section.1.enumerated()), id: \.element.env) { rIndex, setting in
                        TactileSettingRow(s: setting, m: m, showDescription: true)
                            .padding(.vertical, 10)

                        if setting.env == "DM_MIC", m.values["DM_MIC"] == "1" {
                            Rectangle().fill(p.line).frame(height: TactileMetrics.hairline)
                            MicrophoneDevicePicker()
                                .padding(.vertical, 10)
                        }

                        if rIndex < section.1.count - 1 {
                            Rectangle().fill(p.line).frame(height: TactileMetrics.hairline)
                        }
                    }
                }
                Rectangle().fill(p.line).frame(height: TactileMetrics.hairline)
            }

            CloudSavesSection()
                .padding(.top, 14)
                .padding(.bottom, 12)

            Rectangle().fill(p.line).frame(height: TactileMetrics.hairline)

            HStack {
                Button("Reset to tested defaults") { m.reset() }
                    .buttonStyle(TactileButtonStyle(.ghost, compact: true))
                    .disabled(!m.changed)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 10)
        }
        .padding(.horizontal, 16)
    }

    private func cardFooter(_ p: TactilePalette) -> some View {
        HStack(spacing: 10) {
            TactileCheckbox(title: "Show this window at launch", isOn: $show)
                .help("Off: the game starts at once. Hold Option while opening the app to see this window again.")

            Spacer(minLength: 8)

            if checking {
                Button("Play without it") {
                    checking = false
                    SaveCheck.apply("offline")
                    done(true)
                }
                .buttonStyle(TactileButtonStyle(.secondary))

                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Checking cloud save…")
                        .font(.system(size: 13, weight: .regular))
                }
                .foregroundStyle(p.primaryFg)
                .frame(height: 32)
                .padding(.horizontal, 12)
                .background(p.primaryBg.opacity(0.85), in: RoundedRectangle(cornerRadius: TactileMetrics.controlRadius, style: .continuous))
            } else {
                Button("Quit") { done(false) }
                    .buttonStyle(TactileButtonStyle(.secondary))

                Button(action: start) {
                    HStack(spacing: 6) {
                        Text("Play")
                        Image(systemName: "return")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(p.primaryFg.opacity(0.75))
                    }
                }
                .buttonStyle(TactileButtonStyle(.primary))
                .keyboardShortcut(.defaultAction)
                .help("Play (Return)")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// Play, once the cloud's save is compared with this Mac's: a save that changed on both sides is the player's pick, not the newer file's (SaveCheck)
    private func start() {
        let folder = SaveCheck.effectiveFolder()
        guard SaveSyncReport.syncEnabled(folder) else { done(true); return }
        check += 1
        checking = true
        let mine = check
        DispatchQueue.global(qos: .userInitiated).async {
            let r = SaveCheck.report(folder: folder)
            DispatchQueue.main.async {
                guard checking, check == mine else { return }   // the player played without it
                checking = false
                switch SaveCheck.ask(r, cancel: "Cancel") {
                case .play(let choice): SaveCheck.apply(choice); done(true)
                case .retry: start()
                case .cancel: break   // back to the window, nothing chosen
                }
            }
        }
    }
}

// MARK: - Tactile setting row

private struct TactileSettingRow: View {
    let s: Setting
    @ObservedObject var m: LauncherModel
    let showDescription: Bool
    @Environment(\.colorScheme) private var scheme

    private var locked: Bool { m.fixed.contains(s.env) || LauncherModel.unavailable[s.env] != nil }

    private var note: String {
        if let why = LauncherModel.unavailable[s.env] { return why }
        let baseNote = showDescription ? s.note : ""
        guard locked else { return baseNote }
        let lockReason = m.fromLaunch.contains(s.env) ? "Set at launch" : "Set by an env file"
        return baseNote.isEmpty ? lockReason : baseNote + " · " + lockReason
    }

    private var rangeValue: Binding<Double> {
        Binding(
            get: { Double(m.values[s.env] ?? s.def) ?? s.max ?? 1 },
            set: { m.values[s.env] = String(format: "%.2f", $0) }
        )
    }

    private var toggleValue: Binding<Bool> {
        Binding(
            get: { (m.values[s.env] ?? s.def) == s.onValue },
            set: { m.values[s.env] = $0 ? s.onValue : s.offValue }
        )
    }

    private func useSegmented(_ options: [[String]]) -> Bool {
        guard options.count >= 2 && options.count <= 3 else { return false }
        let totalChars = options.reduce(0) { $0 + $1[1].count }
        return totalChars <= 26
    }

    var body: some View {
        let p = TactilePalette(scheme)
        Group {
            switch s.kind {
            case "choice":
                let options = offeredOptions(s, current: m.values[s.env])
                HStack(alignment: .center, spacing: 12) {
                    labelBlock(p)
                    Spacer(minLength: 8)
                    if useSegmented(options) {
                        TactilePillSegment(
                            items: options.map { ($0[0], $0[1]) },
                            selection: m.binding(s),
                            pillShape: false
                        )
                    } else {
                        TactileMenuPicker(options: options, selection: m.binding(s))
                    }
                }
            case "range":
                let valueText = m.rangeLabel(s, rangeValue.wrappedValue)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        labelBlock(p)
                        Spacer(minLength: 8)
                        Text(valueText)
                            .font(.system(size: 12, weight: .regular))
                            .monospacedDigit()
                            .foregroundStyle(p.ink11)
                            .fixedSize()
                    }
                    TactileSlider(
                        value: rangeValue,
                        range: (s.min ?? 0)...(s.max ?? 1),
                        step: s.step ?? 0.05,
                        label: s.label,
                        valueLabel: valueText
                    )
                }
            default:
                HStack(alignment: .center, spacing: 12) {
                    labelBlock(p)
                    Spacer(minLength: 8)
                    TactileSwitch(isOn: toggleValue)
                }
            }
        }
        .disabled(locked)
    }

    private func labelBlock(_ p: TactilePalette) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(s.label)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(locked ? p.ink11 : p.ink12)
            if !note.isEmpty {
                Text(note)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(p.ink11)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Microphone input picker (CoreAudio, shown when DM_MIC == "1")

private struct MicrophoneDevicePicker: View {
    @AppStorage("launcher.DM_MIC_DEVICE") private var savedDevice = "default"
    @State private var devices = MicrophoneInputDevices.list()
    @Environment(\.colorScheme) private var scheme

    private var pickerOptions: [[String]] {
        var list: [[String]] = [["default", "System default"]]
        if savedDevice != "default", !devices.contains(where: { $0.uid == savedDevice }) {
            list.append([savedDevice, "Selected device unavailable"])
        }
        for d in devices { list.append([d.uid, d.name]) }
        return list
    }

    var body: some View {
        let p = TactilePalette(scheme)
        HStack(alignment: .center, spacing: 12) {
            Text("Microphone input")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(p.ink12)
            Spacer(minLength: 8)
            if let uid = getenv("DM_MIC_DEVICE") {
                let value = String(cString: uid)
                Text(devices.first { $0.uid == value }?.name ?? "System default")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(p.ink11)
                    .lineLimit(1)
            } else {
                TactileMenuPicker(options: pickerOptions, selection: $savedDevice)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            devices = MicrophoneInputDevices.list()
        }
    }
}

private struct MicrophoneInputDevice: Identifiable, Hashable {
    let uid: String
    let name: String
    var id: String { uid }
}

private enum MicrophoneInputDevices {
    static func list() -> [MicrophoneInputDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioDeviceID>.size) else { return [] }
        var ids = [AudioDeviceID](repeating: kAudioObjectUnknown, count: Int(size) / MemoryLayout<AudioDeviceID>.stride)
        let status = ids.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, bytes.baseAddress!)
        }
        guard status == noErr else { return [] }
        return ids.compactMap { device in
            guard hasInput(device), let uid = string(device, selector: kAudioDevicePropertyDeviceUID),
                  let name = string(device, selector: kAudioObjectPropertyName), !uid.isEmpty else { return nil }
            return MicrophoneInputDevice(uid: uid, name: dualSenseOverUSB(device) ? "\(name) (USB)" : name)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func hasInput(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioDevicePropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioBufferList>.size) else { return false }
        let data = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { data.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, data) == noErr else { return false }
        let buffers = UnsafeMutableAudioBufferListPointer(data.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.contains { $0.mNumberChannels > 0 }
    }

    // A DualSense or DualSense Edge on USB: CoreAudio exposes its USB VID:PID at the end of ModelUID ("<name>:054C:0CE6" / ":0DF2").
    private static func dualSenseOverUSB(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr,
              transport == kAudioDeviceTransportTypeUSB,
              let model = string(device, selector: kAudioDevicePropertyModelUID) else { return false }
        let parts = model.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 3,
              let vid = UInt32(parts[parts.count - 2], radix: 16),
              let pid = UInt32(parts[parts.count - 1], radix: 16) else { return false }
        return vid == 0x054C && (pid == 0x0CE6 || pid == 0x0DF2)
    }

    private static func string(_ device: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, UnsafeMutableRawPointer(pointer))
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }
}

// MARK: - Cloud saves section

/// Cloud saves: a folder the save is synced through (dm/host/save_sync.h), the one the iPhone app picks in its launcher's Cloud saves section. It is kept in this app's
/// preferences as cloudSaves.folder, which launcher.c puts into DM_SAVE_SYNC before the host starts; a DM_SAVE_SYNC an env file or the launch environment set wins, and is shown here.
struct CloudSavesSection: View {
    @AppStorage("cloudSaves.folder") private var folder = ""
    @Environment(\.colorScheme) private var scheme

    private let fixed: String? = {
        let env = ProcessInfo.processInfo.environment
        let keys = ((env["DM_ENV_FILE_KEYS"] ?? "") + " " + (env["DM_ENV_LAUNCH_KEYS"] ?? "")).split(separator: " ")
        return keys.contains("DM_SAVE_SYNC") || env["DM_SAVE_SYNC"] != nil ? env["DM_SAVE_SYNC"] : nil
    }()

    var body: some View {
        let p = TactilePalette(scheme)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Cloud saves")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(p.ink11)
                Spacer(minLength: 8)
                Text(fixed.map { "\(Self.shown($0)) (env.txt)" } ?? (folder.isEmpty ? "Off" : Self.shown(folder)))
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(p.ink11)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Text("Choose the iCloud Drive folder the iPhone app uses for this game. The save syncs at launch and after each save; replaced saves are kept in the save's -backups folder.")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(p.ink11)
                .fixedSize(horizontal: false, vertical: true)

            if fixed == nil {
                HStack(spacing: 8) {
                    Button(folder.isEmpty ? "Choose folder…" : "Change folder…", action: choose)
                        .buttonStyle(TactileButtonStyle(.secondary, compact: true))
                    if !folder.isEmpty {
                        Button("Turn off") { folder = "" }
                            .buttonStyle(TactileButtonStyle(.ghost, compact: true))
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Use for cloud saves"
        panel.message = "The folder the iPhone app chose in its launcher's Cloud saves"
        panel.directoryURL = URL(fileURLWithPath: folder.isEmpty ? Self.drive : folder)
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }

    static let drive = NSHomeDirectory() + "/Library/Mobile Documents/com~apple~CloudDocs"   // iCloud Drive, as the Finder shows it

    /// A path under iCloud Drive as the Finder and the Files app name it: iCloud Drive › Documents › dev › Zelda; any other path as it is
    static func shown(_ path: String) -> String {
        guard path == drive || path.hasPrefix(drive + "/") else { return path }
        return (["iCloud Drive"] + path.dropFirst(drive.count).split(separator: "/").map(String.init)).joined(separator: " › ")
    }
}

// When the game was last saved: the newest regular file in DM_SAVE, e.g. "Last played Today at 9:41 PM"
private func macLastPlayed() -> String? {
    guard let s = getenv("DM_SAVE") else { return nil }
    let root = URL(fileURLWithPath: String(cString: s))
    guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) else { return nil }
    var newest: Date?
    for case let u as URL in e {
        guard let v = try? u.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
              v.isRegularFile == true, let d = v.contentModificationDate else { continue }
        if newest.map({ d > $0 }) ?? true { newest = d }
    }
    guard let d = newest else { return nil }
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = .short
    f.doesRelativeDateFormatting = true
    return "Last played " + f.string(from: d)
}

// MARK: - Window lifecycle & C entry points

private final class Launcher: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model: LauncherModel
    var window: NSWindow?
    var play = false

    init(_ model: LauncherModel) { self.model = model }

    func applicationDidFinishLaunching(_ n: Notification) {
        let name = info("CFBundleDisplayName") ?? info("CFBundleName") ?? "Game"
        let menu = NSMenu(), item = NSMenuItem(), app = NSMenu()
        app.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        app.addItem(withTitle: "Quit \(name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = app; menu.addItem(item); NSApp.mainMenu = menu

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: TactileMetrics.windowWidth, height: TactileMetrics.windowHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        w.title = name
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.contentMinSize = NSSize(width: TactileMetrics.minWidth, height: TactileMetrics.minHeight)
        window = w
        let host = NSHostingView(rootView: LauncherView(m: model, done: { [weak self] in self?.finish($0) }))
        w.contentView = host
        w.center()
        // no activation and no ordering in front of another app's windows: LaunchServices activates an app opened from Finder or the Dock (applicationDidBecomeActive), open -g does not
        if NSApp.isActive { w.makeKeyAndOrderFront(nil) } else { w.orderBack(nil) }
    }

    func applicationDidBecomeActive(_ n: Notification) { window?.makeKeyAndOrderFront(nil) }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {   // ⌘Q, or a logout or restart: the app ends without the game (exit 0, as Quit)
        fputs("launcher: quit without starting the game\n", stderr)
        return .terminateNow   // not terminateCancel, which a logout or restart takes as a refusal and stops
    }

    func windowWillClose(_ n: Notification) { finish(false) }

    func finish(_ play: Bool) {
        guard let w = window else { return }
        window = nil; self.play = play
        // The main thread blocks in launcher.c's waitpid once run() returns, so the window must leave the screen now: no fade-out (it runs on later run-loop passes),
        // and dmMacLauncher flushes the order-out (AppKit commits it at the end of a pass). Without both, the window stayed on screen, not responding, until the game ended
        w.animationBehavior = .none
        w.delegate = nil; w.orderOut(nil)
        NSApp.stop(nil)
        NSApp.postEvent(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)!, atStart: true)   // run returns at the next event
    }
}

enum LauncherWindowLayout {
    static func fitted(_ frame: NSRect, extraHeight: CGFloat, visible: NSRect) -> NSRect {
        let top = min(frame.maxY, visible.maxY)
        let height = min(frame.height + extraHeight, top - visible.minY)
        return NSRect(x: frame.minX, y: top - height, width: frame.width, height: height)
    }
}

// Called on the main thread after settings and cloud-save decisions. The OS can present
// its consent alert even when the settings window is suppressed.
@_cdecl("dm_mac_microphone_consent")
public func dmMacMicrophoneConsent() -> Int32 {
    switch AVAudioApplication.shared.recordPermission {
    case .granted: return 1
    case .undetermined:
        _ = NSApplication.shared
        var allowed: Bool?
        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async { allowed = granted }
        }
        while allowed == nil {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        if allowed == true {
            fputs("launcher: microphone permission allowed\n", stderr)
            return 1
        }
    default: break
    }
    fputs("launcher: microphone permission denied\n", stderr)
    return 0
}

// 1: Play (the window's settings are in the environment), 0: the player quit, 2: no window (no launcher.json, or "Show this window at launch" off): launcher.c applies the saved choices
@_cdecl("dm_mac_launcher")
public func dmMacLauncher() -> Int32 {
    guard let url = Bundle.main.resourceURL?.appendingPathComponent("dm/launcher.json"), let data = try? Data(contentsOf: url) else { return 2 }
    guard let file = try? JSONDecoder().decode(SettingsFile.self, from: data), !file.settings.isEmpty else { fputs("[RED] launcher: dm/launcher.json cannot be read; starting the game\n", stderr); return 2 }
    if (UserDefaults.standard.object(forKey: "window.show") as? Bool) == false && !NSEvent.modifierFlags.contains(.option) {
        fputs("launcher: settings window off (hold Option at launch to show it)\n", stderr)
        return SaveCheck.withoutWindow() ? 2 : 0
    }
    let model = LauncherModel(file.settings)
    let app = NSApplication.shared, launcher = Launcher(model)
    app.setActivationPolicy(.regular)
    app.delegate = launcher
    fputs("launcher: \(file.settings.count) settings shown\n", stderr)
    app.run()
    CATransaction.flush()   // finish's order-out
    app.setActivationPolicy(.prohibited)   // the host is the game's app from here on
    guard launcher.play else { fputs("launcher: quit without starting the game\n", stderr); return 0 }
    model.apply()
    return 1
}
