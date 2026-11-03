// DEBUG only: `Pomelo --snapshot-editor <kind> <file> <out.png> [light|dark] [state=editing|edited|working|failed]`
// renders the editor chrome (P27) for <file> on a grey backdrop, writes a PNG and exits; `edited` makes sample
// choices first (a trim range, split points, a crop area, pixelated lines and a drawn box, a reordered, turned and
// shortened page list, an exact size, a quarter turn), so the handles show. The chrome is hosted in a window far
// off-screen and its display cached, since ImageRenderer draws no AppKit-backed control (the confirm button, the
// spinner); glass falls back to the solid background, which a cached display can draw.
#if DEBUG
import AppKit
import PomeloCore
import PomeloUIModel
import SwiftUI

enum EditorSnapshot {
    static let flag = "--snapshot-editor"

    enum State: String, CaseIterable {
        case editing, edited, working, failed
    }

    static var usage: String {
        let kinds = EditorKind.allCases.map(\.rawValue).joined(separator: "|")
        let states = State.allCases.map(\.rawValue).joined(separator: "|")
        return "usage: Pomelo \(flag) <\(kinds)> <file> <out.png> [light|dark] [state=\(states)]"
    }

    @MainActor
    static func runIfRequested(arguments: [String]) -> Bool {
        guard var rest = DebugOutput.arguments(after: flag, in: arguments) else { return false }
        var state = State.editing
        if let index = rest.firstIndex(where: { $0.hasPrefix("state=") }) {
            guard let parsed = State(rawValue: String(rest[index].dropFirst("state=".count))) else { DebugOutput.fail(usage, 64) }
            state = parsed
            rest.remove(at: index)
        }
        let dark = DebugOutput.takeScheme(from: &rest, at: 3)
        guard rest.count == 3, let kind = EditorKind(rawValue: rest[0]) else { DebugOutput.fail(usage, 64) }
        let file = URL(fileURLWithPath: rest[1])
        let output = URL(fileURLWithPath: rest[2])
        Task { await render(kind, file: file, state: state, dark: dark, to: output) }
        return true
    }

    @MainActor
    private static func render(_ kind: EditorKind, file: URL, state: State, dark: Bool, to output: URL) async {
        guard FileManager.default.fileExists(atPath: file.path) else { DebugOutput.fail("snapshot failed: no file at \(file.path)") }
        guard output.standardizedFileURL != file.standardizedFileURL else {
            DebugOutput.fail("snapshot failed: the output would overwrite the input")
        }
        guard let preset = EditorSessions.preset(for: kind, settings: AppSettings()) else {
            DebugOutput.fail("snapshot failed: no tool for \(kind.rawValue)")
        }
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        NSApp.appearance = appearance
        NSApp.setActivationPolicy(.accessory)

        let request = EditorRequest(kind: kind, preset: preset, files: [file], anchor: .zero, flags: [])
        let session = EditorSessions.make(request, SettingsStore(defaults: EphemeralDefaults()))
        await session.load()
        if state == .edited, let timeline = session as? TimelineSession { timeline.makeSampleChoices() }
        if state == .edited, let crop = session as? CropSession { crop.makeSampleChoices() }
        if state == .edited, let redact = session as? RedactSession { redact.makeSampleChoices() }
        if state == .edited, let pages = session as? PageOrganizerSession { pages.makeSampleChoices() }
        if state == .edited, let resize = session as? ResizeSession { resize.makeSampleChoices() }
        if state == .edited, let rotate = session as? RotateSession { rotate.perform(.rotateRight) }
        var chrome = EditorChromeState(request: request, session: session)
        switch state {
        case .editing, .edited: break
        case .working: chrome.phase = .working(job: UUID())
        case .failed:
            chrome.phase = .failed(WheelAlert(title: "Couldn't save \(chrome.fileLabel)",
                                              subtitle: "The file may be damaged"))
        }
        let host = NSHostingView(rootView: EditorChrome(state: chrome, content: session.makeContent(),
                                                        animatesIn: false, playsMedia: false)
            .padding(16)
            .background(Color(white: dark ? 0.25 : 0.7))
            .environment(\.wheelSolidBackground, true))
        // Key, as the live panel is, so the confirm button draws in the accent colour.
        let window = KeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
                              defer: false)
        await DebugOutput.writeDisplayOffScreen(host, in: window, appearance: appearance, to: output)
        print(output.path)
        exit(0)
    }

    private final class KeyPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }
}

extension TimelineSession {
    /// Grips at a fifth and seven tenths of the way, or cuts at the thirds, with the playhead between.
    func makeSampleChoices() {
        guard let duration = model?.duration else { return }
        switch mode {
        case .trim:
            drag(.start, to: duration * 0.2)
            drag(.end, to: duration * 0.7)
        case .split:
            for fraction in [1.0 / 3, 2.0 / 3] {
                scrub(to: duration * fraction)
                perform(.addPoint)
            }
        }
        scrub(to: duration * 0.45)
    }
}

extension CropSession {
    /// A 4:3 area turned the other way, made a little smaller from its top-left corner.
    func makeSampleChoices() {
        setRatio(.fourThree)
        flip()
        drag(.topLeft, translation: CGSize(width: 0.08, height: 0.08))
        endDrag()
    }
}

extension RedactSession {
    /// The first two lines of text on (the toggle goes mixed), pixelated, and a box drawn by hand.
    func makeSampleChoices() {
        setStyle(.pixelate)
        for box in (model?.boxes ?? []).filter({ $0.kind == .text }).prefix(2) { setOn(box.id, true) }
        pointerChanged(from: CGPoint(x: 300, y: 200), to: CGPoint(x: 420, y: 300), in: CGSize(width: 568, height: 360))
        pointerEnded(from: CGPoint(x: 300, y: 200), in: CGSize(width: 568, height: 360))
    }
}

extension PageOrganizerSession {
    /// The last page moved to the front, the second turned right, the fourth removed, and two pages chosen.
    func makeSampleChoices() {
        guard let count = model?.pages.count, count >= 4 else { return }
        click(count - 1)
        for _ in 0..<(count - 1) { perform(.moveEarlier) }
        click(1)
        perform(.rotateRight)
        click(3)
        perform(.delete)
        click(1)
        click(2, extend: true)
    }
}

extension ResizeSession {
    /// The 1080 × 1080 chip: both fields filled and the lock open.
    func makeSampleChoices() {
        model.choose(.exact(width: 1080, height: 1080))
    }
}

#endif
