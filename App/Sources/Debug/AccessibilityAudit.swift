// The audit behind `--eval-accessibility`: walks the accessibility tree that the app's own windows vend in-process,
// with plain method calls. Never the AXUIElement API against this process, which needs the Accessibility permission.
// SwiftUI builds its part of the tree only once an assistive app has connected (P146), so in-process this judges the
// AppKit views the app made, in a window or hosted by SwiftUI; `pomelo-evals a11y-lint` reads the SwiftUI source.
#if DEBUG || POMELO_EVALS
import AppKit
import PomeloUIModel
import SwiftUI

/// One element VoiceOver would read badly.
struct AccessibilityFinding: Equatable, Codable {
    /// The element's role, e.g. `AXButton`.
    var role: String
    /// Its place in the tree: each ancestor's role, with its label when it has one.
    var path: String
    var problem: String
}

enum AccessibilityAudit {
    /// Roles VoiceOver can act on: each needs a label or a title to be read as more than its role.
    static let controlRoles: Set<NSAccessibility.Role> = [
        .button, .checkBox, .radioButton, .popUpButton, .slider, .textField, .link, .menuButton,
    ]
    /// Parts AppKit draws and VoiceOver names from their subrole alone ("close button", "increment arrow"); without a
    /// connected assistive app their labels read empty.
    static let namedBySubrole: Set<NSAccessibility.Subrole> = [
        .closeButton, .minimizeButton, .zoomButton, .fullScreenButton, .toolbarButton,
        .incrementArrow, .decrementArrow, .incrementPage, .decrementPage,
    ]
    /// P32's separators, which VoiceOver reads aloud as "middle dot" or "em dash". From code points, so the copy
    /// check (CopyStyleTests) does not take this list for UI text.
    static let separatorGlyphs: [Character] = [0x00B7, 0x2014].compactMap(Unicode.Scalar.init).map(Character.init)
    /// Deeper than any real view; stops a tree that loops back on itself.
    private static let maxDepth = 64

    @MainActor
    static func findings(in root: NSAccessibilityElementProtocol) -> [AccessibilityFinding] {
        var found: [AccessibilityFinding] = []
        var visited: Set<ObjectIdentifier> = []
        walk(root, path: [], depth: 0, visited: &visited) { node, path in
            guard !isSwiftUIs(node),
                  !(node.accessibilitySubrole().map(namedBySubrole.contains) ?? false) else { return }
            let role = node.accessibilityRole()
            let names = names(of: node)
            func flag(_ problem: String) {
                found.append(AccessibilityFinding(role: role?.rawValue ?? "unknown", path: path, problem: problem))
            }
            if let role, controlRoles.contains(role), names.isEmpty {
                flag("no label or title")
            } else if role == .image, names.isEmpty {
                flag("an image that is neither hidden nor labeled")
            }
            if names.contains(where: { $0.contains { separatorGlyphs.contains($0) } }) {
                flag("a separator glyph in its label (P32)")
            }
        }
        return found
    }

    @MainActor
    private static func walk(_ element: Any, path: [String], depth: Int, visited: inout Set<ObjectIdentifier>,
                             visit: (NSAccessibilityProtocol, String) -> Void) {
        guard depth < maxDepth, let node = element as? NSAccessibilityProtocol,
              // AppKit leaves hidden views out of the tree, but the subview fallback would not; stopping at a hidden
              // view skips everything it contains too.
              (node as? NSView)?.isHidden != true,
              visited.insert(ObjectIdentifier(node as AnyObject)).inserted else { return }
        let here = path + [describe(node)]
        visit(node, here.joined(separator: " > "))
        let answered = node.accessibilityChildren() ?? []
        var children = answered.filter { $0 is NSAccessibilityProtocol }
        // A hosting view answers no children until an assistive app connects, and a table answers rows of an older
        // kind (NSTableRow) that only the attribute API reads: their subviews stand in (a table's drawn rows).
        if children.isEmpty || children.count < answered.count, let view = node as? NSView { children += view.subviews }
        for child in children {
            walk(child, path: here, depth: depth + 1, visited: &visited, visit: visit)
        }
    }

    /// A view SwiftUI made for one of its own controls (a switch, a text field): SwiftUI labels it in the tree it
    /// builds for an assistive app, which this walk cannot read, so only the AppKit views the app made are judged.
    @MainActor
    private static func isSwiftUIs(_ node: NSAccessibilityProtocol) -> Bool {
        let object: AnyObject = (node as? NSCell)?.controlView ?? node as AnyObject
        return Bundle(for: type(of: object)).bundleIdentifier?.hasPrefix("com.apple.SwiftUI") == true
    }

    /// The label and title, non-empty. A control's cell stands for it in the tree, but a label set on the control
    /// stays on the control, so both are read.
    @MainActor
    private static func names(of node: NSAccessibilityProtocol) -> [String] {
        var sources: [NSAccessibilityProtocol] = [node]
        if let control = (node as? NSCell)?.controlView { sources.append(control) }
        return sources.flatMap { [$0.accessibilityLabel(), $0.accessibilityTitle()] }
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    @MainActor
    private static func describe(_ node: NSAccessibilityProtocol) -> String {
        let role = node.accessibilityRole()?.rawValue ?? "unknown"
        return names(of: node).first.map { "\(role) \"\($0)\"" } ?? role
    }
}

// MARK: The hook

/// `Pomelo --eval-accessibility <corpus> <out.json>`: opens each surface off-screen, audits it, writes
/// `{"findings": [...], "count": n}` and exits. `<corpus>` holds the evals' photo.png, photo.jpg, clip.mov and doc.pdf.
enum AccessibilityEval {
    static let flag = "--eval-accessibility"
    static let usage = "usage: Pomelo \(flag) <corpus folder> <out.json>"
    /// Off every screen, where the wheel and editor measurements open their panels too.
    static let offScreen = NSPoint(x: -30_000, y: -30_000)
    /// Lets SwiftUI lay out and an editor finish loading its file.
    private static let settle: Duration = .seconds(1)

    struct Report: Codable {
        var findings: [AccessibilityFinding]
        var count: Int
    }

    @MainActor
    static func run(corpus: URL, output: URL, environment: AppEnvironment) async {
        var findings: [AccessibilityFinding] = []
        func audit(_ surface: String, _ root: NSAccessibilityElementProtocol) {
            findings += AccessibilityAudit.findings(in: root).map {
                AccessibilityFinding(role: $0.role, path: "\(surface): \($0.path)", problem: $0.problem)
            }
        }
        await auditWheel(file: corpus.appending(path: "photo.png"), environment: environment, audit: audit)
        for state in [PillSnapshot.State.stack, .expanded] {
            await auditHosted(PillSnapshot.stack(for: state).padding(16)) { audit("pill.\(state.rawValue)", $0) }
        }
        await auditEditors(corpus: corpus, environment: environment, audit: audit)
        await auditShelf(corpus: corpus, audit: audit)
        await auditOnboarding(environment: environment, audit: audit)
        await auditSettings(environment: environment, audit: audit)

        let report = Report(findings: findings, count: findings.count)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(report).write(to: output, options: .atomic)
        } catch {
            DebugOutput.fail("cannot write \(output.path): \(error)")
        }
        exit(0)
    }

    @MainActor
    private static func auditWheel(file: URL, environment: AppEnvironment,
                                   audit: (String, NSAccessibilityElementProtocol) -> Void) async {
        await environment.rebuildWheelContent()
        guard let builder = environment.contentBuilder else { DebugOutput.fail("no wheel content") }
        let controller = WheelController(settings: environment.settingsStore, desktop: .offScreen)
        controller.contentBuilder = builder
        controller.open(files: [file], at: offScreen, clickMode: false)
        guard controller.isOpen else { DebugOutput.fail("no wheel for \(file.lastPathComponent)") }
        try? await Task.sleep(for: settle)
        for (index, page) in controller.model.pages.enumerated() {
            controller.model.setPage(index)
            try? await Task.sleep(for: .milliseconds(100))
            audit("wheel.\(page.id)", controller.panel)
        }
        controller.model.showFailure(WheelAlert(title: "Couldn't convert bad.png", subtitle: "The file may be damaged"))
        try? await Task.sleep(for: .milliseconds(100))
        audit("wheel.failure", controller.panel)
        controller.close()
    }

    @MainActor
    private static func auditEditors(corpus: URL, environment: AppEnvironment,
                                     audit: (String, NSAccessibilityElementProtocol) -> Void) async {
        let controller = EditorController(
            settings: environment.settingsStore, perform: { _, _, _, _ in DebugOutput.fail("the audit saved an edit") },
            release: { _, _ in }, desktop: .offScreen
        )
        for kind in EditorKind.allCases {
            let name = switch kind {
            case .trim, .split: "clip.mov"
            case .organizePages: "doc.pdf"
            case .crop: "photo.png"
            case .targetSize, .redact, .resize, .rotate: "photo.jpg"
            }
            guard let preset = EditorSessions.preset(for: kind, settings: environment.settingsStore.settings) else {
                DebugOutput.fail("no tool opens the \(kind.rawValue) editor")
            }
            controller.open(EditorRequest(kind: kind, preset: preset, files: [corpus.appending(path: name)],
                                          anchor: offScreen, flags: []))
            guard controller.isOpen else { DebugOutput.fail("no \(kind.rawValue) editor") }
            try? await Task.sleep(for: settle)
            audit("editor.\(kind.rawValue)", controller.panel)
            controller.cancel()
        }
    }

    /// The Shelf (S22) holding one file, several, as the list, and with a file gone. The files are copies in a
    /// private folder, so the one deleted is the audit's own.
    @MainActor
    private static func auditShelf(corpus: URL, audit: (String, NSAccessibilityElementProtocol) -> Void) async {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Pomelo Audit Shelf \(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = ["photo.png", "photo.jpg", "doc.pdf"].compactMap { name -> URL? in
            let copy = folder.appending(path: name)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return (try? FileManager.default.copyItem(at: corpus.appending(path: name), to: copy)) == nil ? nil : copy
        }
        guard files.count == 3 else { DebugOutput.fail("cannot copy the Shelf's files") }
        let shelf = ShelfController(desktop: .offScreen, pasteboard: .withUniqueName(), reveal: { _ in })
        defer { shelf.clear() }
        func settle(_ state: String) async {
            try? await Task.sleep(for: .milliseconds(200))
            shelf.panel.displayIfNeeded()
            audit("shelf.\(state)", shelf.panel)
        }
        shelf.summon(.tools(files: [files[0]], at: offScreen))
        await settle("one")
        shelf.add(Array(files.dropFirst()))
        await settle("many")
        shelf.expand()
        await settle("expanded")
        try? FileManager.default.removeItem(at: files[1])
        await shelf.resolve(shelf.model.items.map(\.id))
        await settle("missing")
        shelf.tuck()
        await settle("tucked")
    }

    @MainActor
    private static func auditOnboarding(environment: AppEnvironment,
                                        audit: (String, NSAccessibilityElementProtocol) -> Void) async {
        // A private folder, as the snapshot uses, so the audit never touches a real practice run.
        let folder = PracticeFolder(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("Pomelo Audit \(UUID().uuidString)", isDirectory: true))
        defer { try? FileManager.default.removeItem(at: folder.directory) }
        await environment.rebuildWheelContent()
        let model = OnboardingModel(trigger: environment.settingsStore.settings.trigger, folder: folder,
                                    wheelContent: { environment.contentBuilder })
        for page in OnboardingPage.allCases {
            model.show(page)
            let view = OnboardingView(model: model, settingsNavigation: SettingsNavigation()) {}
            await auditHosted(view, size: OnboardingController.size) {
                audit(page == .practice ? "onboarding" : "onboarding.page\(page.rawValue + 1)", $0)
            }
        }
        model.teardown()
    }

    @MainActor
    private static func auditSettings(environment: AppEnvironment,
                                      audit: (String, NSAccessibilityElementProtocol) -> Void) async {
        await environment.refreshEngines()
        // The samples fill the two panes whose rows otherwise depend on the machine (engines, folders).
        SettingsSnapshot.showSampleWatchFolders(in: environment)
        for pane in SettingsPane.allCases {
            let view = SettingsView(environment: environment, pane: pane,
                                    engines: pane == .engines ? EnginesModel.sampleForSnapshot() : nil)
            await auditHosted(view, size: pane.size) { audit("settings.\(pane.rawValue)", $0) }
        }
    }

    /// Hosts `view` in a window off-screen, as the live windows host theirs, and audits the window.
    @MainActor
    private static func auditHosted(_ view: some View, size: CGSize? = nil,
                                    audit: (NSAccessibilityElementProtocol) -> Void) async {
        let host = NSHostingView(rootView: view)
        let size = size ?? host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: offScreen, size: size), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        // As in every production window: the default lets a close free the window while it is still in use.
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(offScreen)
        window.orderFrontRegardless()
        try? await Task.sleep(for: settle)
        // A table makes its rows as it draws: an off-screen window that never drew would have none to judge.
        window.displayIfNeeded()
        audit(window)
        window.orderOut(nil)
    }
}
#endif
