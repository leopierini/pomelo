import AppKit
import Carbon.HIToolbox
import Foundation
import PomeloCore
import PomeloUIModel
import Testing
@testable import Pomelo

@Suite struct WheelKeysTests {
    @Test func arrowsTabReturnEnterAndEscapeMap() {
        let cases: [(Int, NavKey)] = [
            (kVK_LeftArrow, .left), (kVK_RightArrow, .right), (kVK_UpArrow, .up), (kVK_DownArrow, .down),
            (kVK_Tab, .tab), (kVK_Return, .enter), (kVK_ANSI_KeypadEnter, .enter), (kVK_Escape, .escape),
        ]
        for (code, key) in cases {
            // Arrow keys carry the function and numeric-pad flags; they must not block the mapping.
            #expect(NavKey(keyCode: UInt16(code), modifiers: [.function, .numericPad]) == key)
            #expect(NavKey(keyCode: UInt16(code), modifiers: []) == key)
        }
    }

    @Test func digitsOneToEightMapOnTheTopRowAndTheKeypad() {
        let row = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8]
        let pad = [kVK_ANSI_Keypad1, kVK_ANSI_Keypad2, kVK_ANSI_Keypad3, kVK_ANSI_Keypad4,
                   kVK_ANSI_Keypad5, kVK_ANSI_Keypad6, kVK_ANSI_Keypad7, kVK_ANSI_Keypad8]
        for (index, code) in row.enumerated() {
            #expect(NavKey(keyCode: UInt16(code), modifiers: []) == .digit(index + 1))
            // Shift is allowed: the top-row digits need it on some layouts (AZERTY).
            #expect(NavKey(keyCode: UInt16(code), modifiers: .shift) == .digit(index + 1))
        }
        for (index, code) in pad.enumerated() {
            #expect(NavKey(keyCode: UInt16(code), modifiers: .numericPad) == .digit(index + 1))
        }
    }

    @Test func otherKeysAndCommandOptionControlChordsDoNotMap() {
        for code in [kVK_ANSI_9, kVK_ANSI_0, kVK_ANSI_K, kVK_Space, kVK_Delete] {
            #expect(NavKey(keyCode: UInt16(code), modifiers: []) == nil)
        }
        for flag: NSEvent.ModifierFlags in [.command, .option, .control] {
            #expect(NavKey(keyCode: UInt16(kVK_RightArrow), modifiers: flag) == nil)
            #expect(NavKey(keyCode: UInt16(kVK_ANSI_1), modifiers: flag) == nil)
        }
    }
}

@Suite struct FinderSelectionTests {
    private func list(_ strings: [String]) -> NSAppleEventDescriptor {
        let list = NSAppleEventDescriptor.list()
        for (index, string) in strings.enumerated() {
            list.insert(NSAppleEventDescriptor(string: string), at: index + 1)
        }
        return list
    }

    @Test func aListOfPathsGivesFileURLsInOrder() {
        let urls = FinderSelection.urls(from: list(["/Users/me/A photo.heic", "/Users/me/Folder/"]))
        #expect(urls == [URL(fileURLWithPath: "/Users/me/A photo.heic"),
                         URL(fileURLWithPath: "/Users/me/Folder/", isDirectory: true)])
        #expect(urls[1].hasDirectoryPath)
    }

    @Test func anEmptyListGivesNoURLs() {
        #expect(FinderSelection.urls(from: list([])).isEmpty)
    }

    @Test func oneItemGivesOneURLWhetherListedOrBare() {
        #expect(FinderSelection.urls(from: list(["/tmp/a.png"])) == [URL(fileURLWithPath: "/tmp/a.png")])
        #expect(FinderSelection.urls(from: NSAppleEventDescriptor(string: "/tmp/a.png"))
                == [URL(fileURLWithPath: "/tmp/a.png")])
    }

    @Test func fileURLAndAliasItemsAreReadToo() {
        let list = NSAppleEventDescriptor.list()
        list.insert(NSAppleEventDescriptor(fileURL: URL(fileURLWithPath: "/tmp/b.png")), at: 1)
        #expect(FinderSelection.urls(from: list) == [URL(fileURLWithPath: "/tmp/b.png")])
    }

    @Test func blankItemsAndRelativePathsAreSkipped() {
        #expect(FinderSelection.urls(from: list(["", "relative/path", "/tmp/c.png"]))
                == [URL(fileURLWithPath: "/tmp/c.png")])
    }

    @Test func errorNumbersMapToErrors() {
        func error(_ number: Int) -> FinderSelection.Error {
            FinderSelection.error(from: [NSAppleScript.errorNumber: number, NSAppleScript.errorMessage: "raw"])
        }
        #expect(error(-1743) == .notAuthorized)
        #expect(error(-600) == .finderNotRunning)
        #expect(error(-1712) == .timedOut)
        #expect(error(-1728) == .failed(code: -1728))
        #expect(FinderSelection.error(from: [:]) == .failed(code: nil))
    }
}

@MainActor
@Suite struct ServicesProviderTests {
    @Test func theServiceHandsOverTheFilesOnThePasteboard() {
        let pboard = NSPasteboard.withUniqueName()
        defer { pboard.releaseGlobally() }
        let files = [URL(fileURLWithPath: "/tmp/a.heic"), URL(fileURLWithPath: "/tmp/b.heic")]
        pboard.clearContents()
        pboard.writeObjects(files as [NSURL])
        var received: [URL] = []
        let provider = ServicesProvider { received = $0 }
        var error: NSString?
        provider.convertFiles(pboard, userData: nil, error: &error)
        #expect(received == files)
        #expect(error == nil)
    }

    @Test func aPasteboardWithoutFilesReportsAnErrorAndOpensNothing() {
        let pboard = NSPasteboard.withUniqueName()
        defer { pboard.releaseGlobally() }
        pboard.clearContents()
        pboard.setString("not a file", forType: .string)
        var called = false
        let provider = ServicesProvider { _ in called = true }
        var error: NSString?
        provider.convertFiles(pboard, userData: nil, error: &error)
        #expect(!called)
        #expect(error != nil)
    }

    // The Services machinery reaches the provider by name only (NSMessage + ":userData:error:"): no compiler or
    // Periphery check sees that use, so renaming or removing the method would silently break the Services menu.
    @Test func servicesProviderStillAnswersItsSelector() throws {
        let services = try #require(Bundle.main.object(forInfoDictionaryKey: "NSServices") as? [[String: Any]])
        let messages = services.compactMap { $0["NSMessage"] as? String }
        #expect(!messages.isEmpty)
        #expect(messages.count == services.count)
        let provider = ServicesProvider { _ in }
        for message in messages {
            #expect(provider.responds(to: NSSelectorFromString("\(message):userData:error:")), "\(message)")
        }
    }
}

/// S17: ⌥⌘K goes to a key Shelf first, and then nothing reads Finder.
@MainActor
@Suite(.serialized) struct ClickModeShelfHotkeyTests {
    private final class Reads: @unchecked Sendable { var count = 0 }

    private func makeClickMode(reads: Reads) -> ClickModeController {
        let settings = SettingsStore(defaults: EphemeralDefaults())
        let wheel = WheelController(settings: settings, desktop: .offScreen)
        let clickMode = ClickModeController(wheel: wheel)
        clickMode.isFinderFrontmost = { true }
        clickMode.readSelection = { reads.count += 1; return [] }
        return clickMode
    }

    @Test func hotkeyGoesToAKeyShelf() async {
        let reads = Reads()
        let clickMode = makeClickMode(reads: reads)
        var asked = 0
        clickMode.shelfTakesHotkey = { asked += 1; return true }
        clickMode.hotkeyPressed()
        for _ in 0..<5 { await Task.yield() }
        #expect(asked == 1)
        #expect(reads.count == 0)
    }

    @Test func hotkeyReadsFinderWhenTheShelfDoesNotTakeIt() async throws {
        let reads = Reads()
        let clickMode = makeClickMode(reads: reads)
        clickMode.shelfTakesHotkey = { false }
        clickMode.hotkeyPressed()
        for _ in 0..<100 where reads.count == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(reads.count == 1)
    }
}

/// P23: click mode has no notices. Only a denied Automation permission shows anything (the wheel's red hub).
@Suite struct ClickModeResponseTests {
    @Test func aSelectionOpensTheWheel() {
        let files = [URL(fileURLWithPath: "/tmp/a.heic")]
        #expect(ClickModeResponse(.success(files)) == .open(files))
    }

    @Test func anEmptySelectionDoesNothing() {
        #expect(ClickModeResponse(.success([])) == .ignore)
    }

    @Test func aDeniedAutomationAsksForIt() {
        #expect(ClickModeResponse(.failure(FinderSelection.Error.notAuthorized)) == .askForAutomation)
    }

    @Test func otherErrorsDoNothingVisible() {
        struct Other: Error {}
        let errors: [any Error] = [FinderSelection.Error.timedOut, FinderSelection.Error.finderNotRunning,
                                   FinderSelection.Error.failed(code: -1728), Other()]
        for error in errors {
            #expect(ClickModeResponse(.failure(error)) == .ignore)
        }
    }

    @Test func theAutomationSettingsURLIsThePrivacyPane() {
        #expect(FinderSelection.automationSettingsURL.absoluteString
                == "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
    }
}

/// P23: a denied Automation permission opens the click-mode wheel with no slices and a red hub that is a button.
/// The panel opens off-screen without becoming key, so it never takes the focus of whoever runs the tests.
@MainActor
@Suite(.serialized) struct AutomationPromptTests {
    private func makeWheel(opened: @escaping (URL) -> Void) -> WheelController {
        let settings = SettingsStore(defaults: EphemeralDefaults())
        return WheelController(settings: settings, openURL: opened, desktop: .offScreen)
    }

    @Test func thePromptHasNoSlicesAndARedHub() {
        let model = WheelModel()
        model.load(prompt: .allowAutomation)
        #expect(model.pages.isEmpty && model.slices.isEmpty && model.files.isEmpty)
        #expect(model.alert == WheelAlert(title: "Allow Pomelo to read Finder's selection",
                                          subtitle: "Click to open System Settings", symbol: "hand.raised.fill"))
        // The hub is the only target: everything else is outside.
        #expect(model.geometry.hitTest(.zero) == .hub)
        #expect(model.geometry.hitTest(CGPoint(x: 0, y: 120)) == .outside)

        // Loading files clears the prompt.
        let empty = RoutePlanner(edges: [], enginePriority: [])
        let builder = WheelContentBuilder(formats: .builtIn, available: empty, all: empty, installHints: [:], tools: [])
        let file = URL(fileURLWithPath: "/tmp/a.txt")
        model.load(pages: builder.pages(for: [file]), files: [file], builder: builder)
        #expect(model.prompt == nil && model.alert == nil)
    }

    @Test func activatingThePromptOpensTheAutomationPaneAndCloses() {
        var opened: [URL] = []
        let wheel = makeWheel { opened.append($0) }
        defer { wheel.close() }

        wheel.showAutomationPrompt(at: NSEvent.mouseLocation)
        #expect(wheel.isOpen)
        #expect(wheel.model.clickMode)
        #expect(wheel.model.prompt == .allowAutomation)

        wheel.handle(.enter)
        #expect(opened == [FinderSelection.automationSettingsURL])
        #expect(!wheel.isOpen)
    }

    @Test func escapeClosesThePromptWithoutOpeningAnything() {
        var opened: [URL] = []
        let wheel = makeWheel { opened.append($0) }
        defer { wheel.close() }

        wheel.showAutomationPrompt(at: NSEvent.mouseLocation)
        wheel.handle(.right)
        wheel.handle(.digit(1))
        #expect(wheel.isOpen)
        wheel.handle(.escape)
        #expect(!wheel.isOpen)
        #expect(opened.isEmpty)
        // Activating a closed prompt does nothing.
        wheel.activatePrompt()
        #expect(opened.isEmpty)
    }
}

/// "The wheel opens on": the configured page if the files have it, else the first page.
@MainActor
@Suite(.serialized) struct WheelFirstPageTests {
    private let png = URL(fileURLWithPath: "/tmp/pomelo-first-page-test.png")
    private let docx = URL(fileURLWithPath: "/tmp/pomelo-first-page-test.docx")

    private func makeWheel(firstPage: WheelPageKind?) -> WheelController {
        let settings = SettingsStore(defaults: EphemeralDefaults())
        settings.settings.hapticsEnabled = false
        if let firstPage { settings.settings.firstPage = firstPage }
        let wheel = WheelController(settings: settings, desktop: .offScreen)
        let planner = RoutePlanner(edges: [ConversionEdge(from: "png", to: "jpg", engineID: "x", cost: 1, flags: [])],
                                   enginePriority: ["x"])
        wheel.contentBuilder = WheelContentBuilder(formats: .builtIn, available: planner, all: planner,
                                                   installHints: [:], tools: [], visibility: makeZipOnImages)
        return wheel
    }

    @Test func defaultOpensOnConvert() {
        let wheel = makeWheel(firstPage: nil)
        defer { wheel.close() }
        wheel.open(files: [png], at: NSEvent.mouseLocation, clickMode: false)
        #expect(wheel.model.page?.kind == .convert)
    }

    @Test func toolsFirstOpensOnToolsAndTheTriggerAlternates() {
        let wheel = makeWheel(firstPage: .tools)
        defer { wheel.close() }
        wheel.open(files: [png], at: NSEvent.mouseLocation, clickMode: false)
        #expect(wheel.model.pages.map(\.kind) == [.convert, .tools])
        #expect(wheel.model.page?.kind == .tools)
        wheel.cyclePage()
        #expect(wheel.model.page?.kind == .convert)
    }

    @Test func toolsFirstOnAFileWithOnlyFileToolsStillOpensOnTools() {
        let wheel = makeWheel(firstPage: .tools)
        defer { wheel.close() }
        wheel.open(files: [docx], at: NSEvent.mouseLocation, clickMode: false)
        #expect(wheel.model.page?.kind == .tools)
        #expect(wheel.model.slices.map(\.id) == [
            "action.makeZip", "action.copyPaths", "action.copyFiles", "action.revealInFinder", "action.openTerminal",
            "action.shelf",
        ])
    }

    @Test func toolsFirstWithoutAToolsPageOpensOnTheFirstPage() {
        let model = WheelModel()
        let builder = WheelContentBuilder(formats: .builtIn, available: RoutePlanner(edges: [], enginePriority: []),
                                          all: RoutePlanner(edges: [], enginePriority: []), installHints: [:], tools: [])
        let slice = WheelSlice(id: "convert.jpg", title: "JPG", symbol: "photo", kind: .convert("jpg"))
        model.load(pages: [WheelPage(kind: .convert, slices: [slice])], files: [png], builder: builder, firstPage: .tools)
        #expect(model.page?.kind == .convert)
    }

    @Test func clickModeHonoursItAndTabAlternates() {
        let wheel = makeWheel(firstPage: .tools)
        defer { wheel.close() }
        wheel.open(files: [png], at: NSEvent.mouseLocation, clickMode: true)
        #expect(wheel.model.page?.kind == .tools)
        wheel.handle(.tab)
        #expect(wheel.model.page?.kind == .convert)
        wheel.handle(.tab)
        #expect(wheel.model.page?.kind == .tools)
    }
}

/// Files handed over by the Quick Action, `open -a Pomelo` or a drop on the app's icon (P101, P102).
@MainActor
@Suite(.serialized) struct ClickModeOpenFilesTests {
    private let png = URL(fileURLWithPath: "/tmp/pomelo-open-files-test.png")

    private func makeWheel() -> WheelController {
        let settings = SettingsStore(defaults: EphemeralDefaults())
        settings.settings.hapticsEnabled = false
        return WheelController(settings: settings, desktop: .offScreen)
    }

    private func makeBuilder() -> WheelContentBuilder {
        let planner = RoutePlanner(edges: [ConversionEdge(from: "png", to: "jpg", engineID: "x", cost: 1, flags: [])],
                                   enginePriority: ["x"])
        return WheelContentBuilder(formats: .builtIn, available: planner, all: planner, installHints: [:], tools: [])
    }

    @Test func openedFilesWaitForTheWheelThenOpenInClickMode() {
        let wheel = makeWheel()
        defer { wheel.close() }
        let clickMode = ClickModeController(wheel: wheel)

        clickMode.openFiles([png])
        #expect(!wheel.isOpen)

        wheel.contentBuilder = makeBuilder()
        clickMode.contentBecameReady()
        #expect(wheel.isOpen)
        #expect(wheel.model.clickMode)
        #expect(wheel.model.files == [png])

        // Nothing is left waiting: a second "ready" opens nothing again.
        wheel.close()
        clickMode.contentBecameReady()
        #expect(!wheel.isOpen)
    }

    /// The same file can arrive twice (two attachments for it, or two spellings of its path): the wheel shows it once.
    @Test func openedFilesAreTakenOnceEach() {
        let wheel = makeWheel()
        defer { wheel.close() }
        let clickMode = ClickModeController(wheel: wheel)
        wheel.contentBuilder = makeBuilder()

        let again = URL(fileURLWithPath: png.deletingLastPathComponent().path + "/./" + png.lastPathComponent)
        clickMode.openFiles([png, again, png])
        #expect(wheel.isOpen)
        #expect(wheel.model.files == [png])
    }

    @Test func openedNonFileURLsAreIgnored() throws {
        let web = try #require(URL(string: "https://example.com/photo.png"))
        let wheel = makeWheel()
        defer { wheel.close() }
        let clickMode = ClickModeController(wheel: wheel)

        // Before the content is ready, nothing waits for a web address.
        clickMode.openFiles([web])
        wheel.contentBuilder = makeBuilder()
        clickMode.contentBecameReady()
        #expect(!wheel.isOpen)

        clickMode.openFiles([web])
        #expect(!wheel.isOpen)

        clickMode.openFiles([web, png])
        #expect(wheel.isOpen)
        #expect(wheel.model.files == [png])
    }
}

/// `open -a Pomelo x.png`, a drop on the icon and the Quick Action arrive as an Open Documents Apple Event (P102).
/// Dispatched in-process, so no other app and no LaunchServices are involved; the test host never plans the wheel,
/// so the files wait in click mode and nothing opens.
@MainActor
@Suite(.serialized) struct OpenDocumentsEventTests {
    @Test func anOpenDocumentsEventReachesClickMode() async throws {
        let file = URL(fileURLWithPath: "/tmp/pomelo-open-documents-\(UUID().uuidString).png")
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenDocuments),
            targetDescriptor: .currentProcess(), returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        let list = NSAppleEventDescriptor.list()
        list.insert(NSAppleEventDescriptor(fileURL: file), at: 1)
        event.setParam(list, forKeyword: keyDirectObject)
        // On the heap and never freed, so it outlives this test (below).
        let reply = UnsafeMutablePointer<AppleEvent>.allocate(capacity: 1)
        reply.initialize(to: AppleEvent())
        // The manager finds AppKit's handler itself; the reference constant is never read.
        var unused = 0
        let status = withUnsafeMutablePointer(to: &unused) { refCon in
            NSAppleEventManager.shared().dispatchRawAppleEvent(
                event.aeDesc!, withRawReply: reply, handlerRefCon: UnsafeMutableRawPointer(refCon))
        }
        #expect(status == noErr)

        let clickMode = AppEnvironment.shared.clickMode
        let deadline = ContinuousClock.now + .seconds(2)
        while clickMode.pendingFiles?.contains(file) != true, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(clickMode.pendingFiles?.contains(file) == true)
        #expect(!AppEnvironment.shared.wheel.isOpen)

        // P149: AppKit fills the reply from the event in a block it defers behind any window animation, even after
        // the files arrived (it ran in the next suite and crashed the host, SIGBUS in AEGetParamDesc), so both are
        // kept for good: a few bytes the test host leaks on purpose.
        _ = Unmanaged.passRetained(event)
    }
}
