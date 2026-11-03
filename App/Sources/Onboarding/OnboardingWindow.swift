// The welcome window, three pages: a hands-on practice of the gesture (drag the sample photo, tap the trigger key
// mid-drag, drop it on PNG), the wheel's other pages, and what can be made one's own. Shown at launch until it is
// finished or closed once, and from the menu's "Show Welcome".
import AppKit
import PomeloUIModel
import SwiftUI

/// The welcome's pages, in order.
enum OnboardingPage: Int, CaseIterable {
    case practice, morePages, makeItYours

    var previous: OnboardingPage? { OnboardingPage(rawValue: rawValue - 1) }
    var next: OnboardingPage? { OnboardingPage(rawValue: rawValue + 1) }
    var isLast: Bool { next == nil }
}

/// The state behind the pages and the practice's three steps.
@MainActor
final class OnboardingModel: ObservableObject {
    let trigger: TriggerKey
    /// Whether ⌥⌘K opens the wheel on Finder's selection, so the welcome mentions it.
    let hotkeyEnabled: Bool
    let folder: PracticeFolder
    /// The practice copy of the sample, or nil when it could not be prepared.
    let practiceFile: URL?
    let errorMessage: String?
    /// Step 2: the trigger key is down right now.
    @Published private(set) var triggerHeld = false
    /// Step 3: the PNG has appeared in the practice folder.
    @Published private(set) var converted = false
    @Published private(set) var page = OnboardingPage.practice
    /// The real wheel's pages for the practice photo, drawn small on the second page; a kind without one shows a
    /// plain card instead.
    @Published private(set) var wheels: [WheelPageKind: WheelModel] = [:]

    /// The app's current wheel content. Read when the second page is first shown, not at launch: the first launch's
    /// welcome opens before the content is built.
    private let wheelContent: @MainActor () -> WheelContentBuilder?
    private var watcher: PracticeFolderWatcher?
    private var pollTimer: Timer?

    init(trigger: TriggerKey, hotkeyEnabled: Bool = true, folder: PracticeFolder,
         bundledSample: URL? = Bundle.main.url(forResource: "Sample", withExtension: "heic"),
         wheelContent: @escaping @MainActor () -> WheelContentBuilder? = { nil }) {
        self.trigger = trigger
        self.hotkeyEnabled = hotkeyEnabled
        self.folder = folder
        self.wheelContent = wheelContent
        var file: URL?
        var message: String?
        if let bundledSample {
            do { file = try folder.prepare(copying: bundledSample) } catch {
                message = "Couldn't prepare the practice photo: \(error.localizedDescription)"
            }
        } else {
            message = "The practice photo is missing from the app."
        }
        practiceFile = file
        errorMessage = message
        if file != nil {
            watcher = PracticeFolderWatcher(directory: folder.directory) { [weak self] in self?.refreshConverted() }
        }
    }

    /// The practice photo, decoded once for the first page's card and the wheels' hubs.
    private(set) lazy var photo: NSImage? = practiceFile.flatMap { NSImage(contentsOf: $0) }

    /// Next on every page but the last, where the same button is Done and calls `finish`.
    func advance(finish: () -> Void) {
        guard let next = page.next else { return finish() }
        show(next)
    }

    func goBack() {
        if let previous = page.previous { show(previous) }
    }

    func show(_ page: OnboardingPage) {
        if page == .morePages { prepareWheels() }
        self.page = page
    }

    /// Plans the wheel for the practice photo once, the way the wheel in use does when the photo is dragged.
    private func prepareWheels() {
        guard wheels.isEmpty, let file = practiceFile, let builder = wheelContent() else { return }
        let pages = builder.pages(for: [file])
        var made: [WheelPageKind: WheelModel] = [:]
        for kind in WheelPageKind.allCases {
            guard let index = pages.firstIndex(where: { $0.kind == kind }) else { continue }
            let wheel = WheelModel()
            wheel.trigger = trigger
            wheel.load(pages: pages, files: [file], builder: builder, firstPage: kind)
            wheel.setPage(index)
            wheel.thumbnail = photo
            made[kind] = wheel
        }
        wheels = made
    }

    /// Whether the `trigger` key is part of `flags`.
    static func isHeld(_ trigger: TriggerKey, in flags: NSEvent.ModifierFlags) -> Bool {
        DragMonitor.modifierSet(flags).contains(trigger.modifier)
    }

    /// Polls the modifier keys while the window is key, so the glyph lights up with the key. Reading the flags
    /// needs no permission.
    func setPollingModifiers(_ on: Bool) {
        pollTimer?.invalidate()
        pollTimer = nil
        triggerHeld = false
        guard on else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let held = Self.isHeld(self.trigger, in: NSEvent.modifierFlags)
                if held != self.triggerHeld { self.triggerHeld = held }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    #if DEBUG
    /// For the snapshot tool: draws the key glyph as held.
    func simulateTriggerHeld() { triggerHeld = true }
    #endif

    func refreshConverted() {
        let now = folder.hasConvertedOutput
        if now != converted { converted = now }
    }

    /// Stops the file watcher and the modifier poll.
    func teardown() {
        watcher?.stop()
        watcher = nil
        setPollingModifiers(false)
    }
}

/// Owns the welcome window. One window at a time; showing it again brings it to the front.
@MainActor
final class OnboardingController: NSObject, NSWindowDelegate {
    static let size = CGSize(width: 600, height: 450)

    private let settings: SettingsStore
    /// Where each practice run's folder is made; tests pass their own.
    private let practiceRoot: URL
    /// The last page's Open Settings button asks it for the Wheel pane.
    private let settingsNavigation: SettingsNavigation
    /// The app's wheel content, for the second page; set by `AppEnvironment` once it exists.
    var wheelContent: @MainActor () -> WheelContentBuilder? = { nil }
    private(set) var window: NSWindow?
    private(set) var model: OnboardingModel?

    init(settings: SettingsStore, practiceRoot: URL = PracticeFolder.standardRoot,
         settingsNavigation: SettingsNavigation = SettingsNavigation()) {
        self.settings = settings
        self.practiceRoot = practiceRoot
        self.settingsNavigation = settingsNavigation
    }

    var isShowing: Bool { window?.isVisible == true }

    /// The welcome's window, shared with the DEBUG snapshot so both look the same: the title bar is transparent and
    /// its title hidden, because the view's own header says "Welcome to Pomelo" (the title stays for VoiceOver and
    /// the Window menu).
    static func makeWindow(content: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Welcome to Pomelo"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        // The default lets a close free the window while something still reads it.
        window.isReleasedWhenClosed = false
        window.contentView = content
        return window
    }

    /// Opens the window (a fresh practice each time) and brings it in front of other apps.
    func show() {
        if let window, window.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let model = OnboardingModel(trigger: settings.settings.trigger,
                                    hotkeyEnabled: settings.settings.clickModeHotkeyEnabled,
                                    folder: .fresh(in: practiceRoot), wheelContent: wheelContent)
        let view = OnboardingView(model: model, settingsNavigation: settingsNavigation) { [weak self] in
            self?.finish()
        }
        let window = Self.makeWindow(content: NSHostingView(rootView: view))
        window.delegate = self
        window.center()
        self.model = model
        self.window = window
        // Seen as soon as it opens: quitting Pomelo with the window open sends no close, and the welcome must not
        // come back at the next launch (P20). The menu's Show Welcome still opens it.
        if !settings.settings.hasCompletedOnboarding { settings.settings.hasCompletedOnboarding = true }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// The last page's Done button: closes the window. The close waits for the next main-actor turn, because
    /// `windowWillClose` tears the content view down and the button's action is still running on it.
    func finish() {
        let closing = window
        DispatchQueue.main.async { closing?.close() }
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) { model?.setPollingModifiers(true) }
    func windowDidResignKey(_ notification: Notification) { model?.setPollingModifiers(false) }

    func windowWillClose(_ notification: Notification) {
        model?.teardown()
        model = nil
        window?.delegate = nil
        window?.contentView = nil
        window = nil
    }
}

// MARK: - Views

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    let settingsNavigation: SettingsNavigation
    let onDone: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openSettings) private var openSettings

    static let shelfSentence = "Shake files while you drag them to keep them on the Shelf."
    static let hotkeySentence = "No drag needed: select files in Finder and press \u{2325}\u{2318}K."
    static let privacySentence = "Everything stays on your Mac, and your originals are never changed."

    static let morePagesTitle = "More than converting"
    static func morePagesSubtitle(glyph: String) -> String {
        "Tap \(glyph) again while you drag to flip the wheel between its pages."
    }

    /// The second page's three wheels, in the wheel's own page order.
    struct WheelCaption: Equatable {
        var kind: WheelPageKind
        var detail: String
        /// The plain card's symbol, when the wheel has no such page.
        var symbol: String
        var title: String { kind.title }
    }

    static let wheelCaptions = [
        WheelCaption(kind: .convert, detail: "50+ formats", symbol: "arrow.triangle.2.circlepath"),
        WheelCaption(kind: .tools, detail: "Compress, crop, resize, redact", symbol: "wrench.and.screwdriver"),
        WheelCaption(kind: .ai, detail: "On device: remove background, smart crop, scan text", symbol: "sparkles"),
    ]

    static let makeItYoursTitle = "Make it yours"
    static let makeItYoursSubtitle = "Pomelo fits the way you already work."
    static let wheelSentence = "Choose what the wheel shows for each kind of file, on up to four pages you name."
    static let automationSentence = "Convert from Shortcuts, from watch folders, or with the Finder Quick Action."

    private var glyph: String { WheelModel.glyph(of: model.trigger) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                pageContent(model.page)
                    .id(model.page)
                    .transition(.opacity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
                .padding(.horizontal, -28)
            footer
                .padding(.top, 14)
        }
        .padding(.horizontal, 28)
        .padding(.top, 26)
        .padding(.bottom, 18)
        .frame(width: OnboardingController.size.width, height: OnboardingController.size.height)
    }

    @ViewBuilder private func pageContent(_ page: OnboardingPage) -> some View {
        switch page {
        case .practice: practicePage
        case .morePages: morePagesPage
        case .makeItYours: makeItYoursPage
        }
    }

    private func change(_ update: () -> Void) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2), update)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            pageDots
            Spacer()
            if model.page.previous != nil {
                Button("Back") { change { model.goBack() } }
                    .controlSize(.large)
            }
            Button(model.page.isLast ? "Done" : "Next") {
                change { model.advance(finish: onDone) }
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
        }
    }

    private var pageDots: some View {
        HStack(spacing: 7) {
            ForEach(OnboardingPage.allCases, id: \.self) { page in
                Circle()
                    .fill(page == model.page ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 7, height: 7)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: model.page)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(model.page.rawValue + 1) of \(OnboardingPage.allCases.count)")
    }

    // MARK: Page 1

    private var practicePage: some View {
        VStack(alignment: .leading, spacing: 0) {
            header(title: "Welcome to Pomelo",
                   subtitle: "Drag files, tap \(glyph), and drop them on what they should become.") {
                Image("AboutIcon")
                    .resizable()
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
            }
            .padding(.bottom, 26)
            Text("Try it once on this photo")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)
            // A converted PNG means the first two steps happened too.
            HStack(alignment: .top, spacing: 12) {
                card(1, "Drag the photo", detail: "Sample.heic", done: model.converted) { photo }
                card(2, "Tap \(glyph)", detail: "while you drag", done: model.triggerHeld || model.converted) { keyCap }
                card(3, "Drop on PNG", detail: model.converted ? "Sample.png is ready" : "in the wheel",
                     done: model.converted) { target }
            }
            if model.hotkeyEnabled {
                Label(Self.hotkeySentence, systemImage: "command")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 16)
            }
        }
    }

    /// A page's header: its picture where page 1 has the app icon, then the title and one line under it.
    private func header<Picture: View>(title: String, subtitle: String,
                                       @ViewBuilder picture: () -> Picture) -> some View {
        HStack(spacing: 16) {
            picture()
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title.weight(.semibold))
                Text(subtitle)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Pages 2 and 3 put a large symbol in the app icon's place, on a tile the icon's size.
    private func headerSymbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 30, weight: .medium))
            .foregroundStyle(Color.accentColor)
            .frame(width: 64, height: 64)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.accentColor.opacity(0.12)))
            .accessibilityHidden(true)
    }

    /// One step: its picture on top, then the number (a checkmark once done), the title and a detail line. The three
    /// cards share one size so the row stays even whatever each picture is.
    private func card<Content: View>(_ number: Int, _ title: String, detail: String, done: Bool,
                                     @ViewBuilder picture: () -> Content) -> some View {
        VStack(spacing: 12) {
            picture()
                .frame(height: 64)
            VStack(spacing: 3) {
                HStack(spacing: 6) {
                    ZStack {
                        Circle().fill(done ? Color.accentColor : Color.secondary.opacity(0.2))
                        if done {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .accessibilityHidden(true)
                        } else {
                            Text("\(number)")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                        }
                    }
                    .frame(width: 18, height: 18)
                    Text(title)
                        .font(.headline)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.08)))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(done ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: done ? 1.5 : 0.5)
        )
        .animation(.easeOut(duration: 0.15), value: done)
        .accessibilityElement(children: .combine)
        .accessibilityValue(done ? "Done" : "")
    }

    // Step 1

    @ViewBuilder private var photo: some View {
        if let file = model.practiceFile {
            Image(nsImage: model.photo ?? Self.placeholderPhoto)
                .resizable()
                .scaledToFill()
                .frame(width: 84, height: 63)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                .onDrag { Self.provider(for: file) }
                .accessibilityLabel("Sample photo. Drag it onto the wheel.")
        } else {
            Text(model.errorMessage ?? "")
                .font(.caption)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
        }
    }

    /// The drag item. A file URL, so `DragMonitor` and the wheel's drop target read it like a Finder drag.
    static func provider(for file: URL) -> NSItemProvider {
        NSItemProvider(object: file as NSURL)
    }

    private static var placeholderPhoto: NSImage {
        NSImage(systemSymbolName: "photo", accessibilityDescription: nil) ?? NSImage()
    }

    // Step 2

    private var keyCap: some View {
        Text(glyph)
            .font(.system(size: 24, weight: .semibold))
            .frame(width: 56, height: 48)
            .background(RoundedRectangle(cornerRadius: 9).fill(model.triggerHeld ? Color.accentColor : Color.secondary.opacity(0.15)))
            .foregroundStyle(model.triggerHeld ? Color.white : Color.primary)
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.secondary.opacity(0.4), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.12), radius: 0, y: 1.5)
            .animation(.easeOut(duration: 0.1), value: model.triggerHeld)
            .accessibilityLabel(model.triggerHeld ? "Trigger key is down" : "Trigger key")
    }

    // Step 3

    @ViewBuilder private var target: some View {
        if model.converted {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.green)
                .accessibilityLabel("It worked: Sample.png created")
        } else {
            Text("PNG")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 64, height: 48)
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                )
                .accessibilityLabel("Waiting for Sample.png")
        }
    }
    // MARK: Page 2

    /// The wheel is drawn 360 pt wide; three fit side by side at this scale.
    private static let wheelScale: CGFloat = 0.4
    /// The empty band the wheel's panel keeps above the ring, left out of the card.
    private static let wheelTopMargin: CGFloat = 22

    private var morePagesPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            header(title: Self.morePagesTitle, subtitle: Self.morePagesSubtitle(glyph: glyph)) {
                headerSymbol("square.stack.3d.up")
            }
            .padding(.bottom, 26)
            Text("The wheel for this photo")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)
            HStack(alignment: .top, spacing: 12) {
                ForEach(Self.wheelCaptions, id: \.kind) { caption in
                    wheelCard(caption)
                }
            }
            // The cards share the tallest one's height, whichever caption wraps.
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func wheelCard(_ caption: WheelCaption) -> some View {
        VStack(spacing: 8) {
            miniWheel(caption)
            VStack(spacing: 3) {
                Text(caption.title)
                    .font(.headline)
                Text(caption.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 10)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5))
    }

    /// The real wheel's page, small and still: a picture, not a control.
    @ViewBuilder private func miniWheel(_ caption: WheelCaption) -> some View {
        let scale = Self.wheelScale
        let size = CGSize(width: WheelView.panelSize.width * scale,
                          height: (WheelView.panelSize.height - Self.wheelTopMargin) * scale)
        if let wheel = model.wheels[caption.kind] {
            WheelView(model: wheel)
                .environment(\.wheelSolidBackground, true)
                .environment(\.wheelSolidFill, Self.wheelFill)
                .scaleEffect(scale)
                .offset(y: -Self.wheelTopMargin / 2 * scale)
                .frame(width: size.width, height: size.height)
                .allowsHitTesting(false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("The wheel's \(caption.title) page")
                .accessibilityAddTraits(.isImage)
        } else {
            Image(systemName: caption.symbol)
                .font(.system(size: 40, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: size.width, height: size.height)
                .accessibilityHidden(true)
        }
    }

    /// A step lighter than the card in both appearances, as the live glass wheel looks over a window.
    private static let wheelFill = Color(nsColor: NSColor(name: nil) { appearance in
        NSColor(white: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0.22 : 0.99, alpha: 1)
    })

    // MARK: Page 3

    private var makeItYoursPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            header(title: Self.makeItYoursTitle, subtitle: Self.makeItYoursSubtitle) {
                headerSymbol("slider.horizontal.3")
            }
            .padding(.bottom, 22)
            VStack(spacing: 10) {
                feature("circle.circle", "Your own wheel", Self.wheelSentence) {
                    Button("Open Settings") { settingsNavigation.open(.wheel, with: openSettings) }
                }
                feature("tray.and.arrow.down", "The Shelf", Self.shelfSentence) { EmptyView() }
                feature("gearshape.2", "Automation", Self.automationSentence) { EmptyView() }
            }
            Label(Self.privacySentence, systemImage: "lock.shield")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 16)
        }
    }

    private func feature<Accessory: View>(_ symbol: String, _ title: String, _ text: String,
                                          @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            accessory()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5))
    }
}
