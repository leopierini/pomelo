// The conversion wheel: a ring of up to 8 slices around a hub that previews the hovered choice, with a page pill
// below. `WheelModel` holds the live state the view, the panel's drop target and the controller share.
import AppKit
import PomeloCore
import PomeloUIModel
import Observation
import QuickLookThumbnailing
import SwiftUI

/// A red hub (P23): something the user should know before (or instead of) choosing a slice; or, in the accent
/// colour, a note on a job that succeeded (P25).
struct WheelAlert: Equatable {
    enum Style: Equatable {
        case failure, note
    }

    var title: String
    var subtitle: String?
    /// An SF Symbol shown in the style's colour above the title.
    var symbol = "exclamationmark.triangle.fill"
    var style = Style.failure

    static func note(title: String, subtitle: String?) -> WheelAlert {
        WheelAlert(title: title, subtitle: subtitle, symbol: "checkmark.circle.fill", style: .note)
    }
}

/// What the wheel is doing (P23).
enum WheelPhase: Equatable {
    /// Slices can be chosen.
    case choosing
    /// A drop landed on a conversion or an engine tool, on whatever page: the wheel waits briefly for the job;
    /// nothing more can be chosen.
    case waiting
    /// The job failed: the hub is red until the wheel is dismissed, and the slices can be chosen again on the same
    /// files (P191); hovering one shows its preview instead.
    case failed(WheelAlert)
    /// The job succeeded with something to say (codes copied, saved to Downloads): an accent hub, slices dimmed.
    case noted(WheelAlert)
}

/// The wheel's live state. The panel's drop target writes the hover; the controller writes everything else.
@MainActor
@Observable
final class WheelModel {
    /// The pages shown: the planned ones, with their conversions disabled when every file is damaged.
    private(set) var pages: [WheelPage] = []
    private(set) var pageIndex = 0
    /// The hovered slice on the current page, hub and outside are nil.
    private(set) var hovered: Int?
    /// The dragged (or, in click mode, selected) files.
    private(set) var files: [URL] = []
    var clickMode = false
    var trigger: TriggerKey = .shift
    /// The first file's thumbnail, or its file-type icon until the thumbnail arrives.
    var thumbnail: NSImage?
    /// Bumped on every open; its change plays the open animation (scale 0.92 → 1 and opacity over 0.15 s).
    private(set) var openCount = 0
    /// The highlight's rotation in radians, clockwise from 12 o'clock. Unwrapped, so it always turns the short way.
    private(set) var highlightAngle: Double = 0
    /// False when the highlight appears from nothing: it then jumps instead of turning.
    private(set) var highlightAnimates = false
    /// The up-front readability check of the files (P23), with the facts for the size estimate; clean until its
    /// result arrives.
    private(set) var readability = FileReadability.Report.clean
    private(set) var phase = WheelPhase.choosing
    /// Click mode's request for a permission (P23): the wheel has no slices and its red hub is a button.
    private(set) var prompt: WheelAlert?
    /// True while a click-closed wheel's panel still takes clicks (M3): nothing of the wheel shows.
    var isContentHidden = false

    @ObservationIgnored private(set) var builder: WheelContentBuilder?
    /// The pages as planned, before a readability verdict disables anything.
    @ObservationIgnored private var plannedPages: [WheelPage] = []
    /// Called when the hovered slice changes (the controller plays the haptic).
    @ObservationIgnored var onHoverChange: ((Int?) -> Void)?
    /// Called when VoiceOver activates the prompt's hub.
    @ObservationIgnored var onActivatePrompt: (() -> Void)?
    /// The last centre-relative point, so a page change can re-hover the slice under it.
    @ObservationIgnored private var lastPoint: CGPoint?

    var page: WheelPage? { pages.indices.contains(pageIndex) ? pages[pageIndex] : nil }
    var slices: [WheelSlice] { page?.slices ?? [] }
    var geometry: WheelGeometry { WheelGeometry(sliceCount: slices.count) }

    /// Shows `pages` for `files`, on the `firstPage` kind if they have it and else on the first page, with nothing
    /// hovered, and plays the open animation.
    func load(pages: [WheelPage], files: [URL], builder: WheelContentBuilder, firstPage: WheelPageKind = .convert) {
        self.pages = pages
        plannedPages = pages
        self.files = files
        self.builder = builder
        readability = .clean
        phase = .choosing
        prompt = nil
        pageIndex = pages.firstIndex { $0.kind == firstPage } ?? 0
        lastPoint = nil
        setHovered(nil)
        openCount += 1
    }

    /// Shows `prompt` in a wheel without files or slices, and plays the open animation.
    func load(prompt: WheelAlert) {
        setHovered(nil)
        pages = []
        plannedPages = []
        files = []
        builder = nil
        thumbnail = nil
        readability = .clean
        phase = .choosing
        self.prompt = prompt
        pageIndex = 0
        lastPoint = nil
        openCount += 1
    }

    /// New plans for the open wheel (an engine got ready after it opened): the same page (by id) stays shown and the
    /// readability verdict applies again. The hovered slice is found again by its id: a rebuild can insert or drop a
    /// slice, so its index may name another choice under a still pointer.
    func replan(pages newPages: [WheelPage], builder: WheelContentBuilder) {
        let shownID = page?.id
        let hoveredID = hovered.map { slices[$0].id }
        plannedPages = newPages
        self.builder = builder
        apply(readability)
        pageIndex = newPages.firstIndex { $0.id == shownID } ?? min(pageIndex, max(newPages.count - 1, 0))
        setHovered(hoveredID.flatMap { id in slices.firstIndex { $0.id == id } })
    }

    /// A drop landed: the hovered slice stays lit while the wheel waits for the job.
    func beginWaiting() {
        phase = .waiting
    }

    /// The job failed: the hub turns red and the slices stay live (P191).
    func showFailure(_ alert: WheelAlert) {
        setHovered(nil)
        phase = .failed(alert)
    }

    /// The job succeeded with a note: the hub shows it in the accent colour and the slices dim.
    func showNote(_ alert: WheelAlert) {
        setHovered(nil)
        phase = .noted(alert)
    }

    var isFailed: Bool {
        if case .failed = phase { true } else { false }
    }

    /// Slices can be hovered and chosen: before a choice, and again after a failure (P191).
    var isChoosable: Bool { phase == .choosing || isFailed }

    /// Only a note dims the slices: after a failure they can be chosen again.
    var dimsSlices: Bool {
        if case .noted = phase { true } else { false }
    }

    /// The hub shows a dropped job's failure or note, which a click or moving well away closes.
    var showsOutcome: Bool {
        switch phase {
        case .failed, .noted: true
        case .choosing, .waiting: false
        }
    }

    /// Applies the readability check, whose facts the hub's size estimate reads. When every file is damaged, every
    /// slice but the file tools (Make Zip and the like: zipping a damaged file is fine) is disabled; when only some
    /// are, conversions and tools skip them.
    func apply(_ report: FileReadability.Report) {
        readability = report
        guard report.allDamaged else {
            pages = plannedPages
            return
        }
        let reason = Self.damagedReason(count: report.damaged.count)
        pages = plannedPages.map { page in
            var page = page
            page.slices = page.slices.map { slice in
                if case .action = slice.kind { return slice }
                var slice = slice
                slice.isEnabled = false
                slice.disabledReason = reason
                return slice
            }
            return page
        }
    }

    /// The files `slice` runs on: an action takes them all, a conversion or tool only the readable ones (a damaged
    /// file could only fail).
    func files(toRun slice: WheelSlice, from files: [URL]) -> [URL] {
        if case .action = slice.kind { return files }
        return readability.readable(files)
    }

    /// Switches to page `index` and re-hovers whatever slice now lies under the last point.
    func setPage(_ index: Int) {
        guard pages.indices.contains(index) else { return }
        // Cleared first: the same index on a page with another slice count is another angle, so the highlight,
        // haptic and hub preview must be recomputed even when the index does not change.
        setHovered(nil)
        pageIndex = index
        hover(at: lastPoint)
    }

    /// Hit-tests `point` (relative to the wheel's centre, y-up) and hovers the slice under it, if any. Once a drop
    /// has landed the hover is frozen (the chosen slice stays lit, nothing is lit under a note) until a failure makes
    /// the wheel live again (P191).
    @discardableResult
    func hover(at point: CGPoint?) -> WheelHit {
        guard isChoosable else { return .outside }
        lastPoint = point
        let hit = point.map { geometry.hitTest($0) } ?? .outside
        if case .slice(let index) = hit { setHovered(index) } else { setHovered(nil) }
        return hit
    }

    /// The slice under `point` (centre-relative, y-up), enabled or not.
    func slice(at point: CGPoint) -> WheelSlice? {
        guard case .slice(let index) = geometry.hitTest(point), slices.indices.contains(index) else { return nil }
        return slices[index]
    }

    func setHovered(_ index: Int?) {
        let index = index.flatMap { slices.indices.contains($0) ? $0 : nil }
        guard index != hovered else { return }
        if let index {
            highlightAnimates = hovered != nil
            highlightAngle = geometry.highlightAngle(toSlice: index, from: highlightAnimates ? highlightAngle : nil)
        }
        hovered = index
        onHoverChange?(index)
    }

    /// The hub's text: the hovered slice's preview (over the files it would run on), else the dragged file's name
    /// or count.
    var preview: HubPreview {
        if let hovered, let builder {
            let slice = slices[hovered]
            return builder.preview(for: slice, files: files(toRun: slice, from: files), facts: readability.facts)
        }
        return HubPreview(title: files.count == 1 ? files[0].lastPathComponent : "\(files.count) files")
    }

    /// The hub's alert, when there is one: a dropped job's note, its failure while no slice is hovered (P191), or
    /// click mode's prompt; else damaged files, while no enabled slice is hovered (hovering an enabled slice previews
    /// it as usual).
    var alert: WheelAlert? {
        switch phase {
        case .noted(let outcome): return outcome
        case .failed(let outcome) where hovered == nil: return outcome
        case .choosing, .waiting, .failed: break
        }
        if let prompt { return prompt }
        guard let damage = damageAlert else { return nil }
        if let hovered, slices[hovered].isEnabled { return nil }
        return damage
    }

    /// "<name> can't be read" or "<n> files can't be read", when the check found damaged files.
    var damageAlert: WheelAlert? {
        let damaged = readability.damaged
        guard !damaged.isEmpty else { return nil }
        let name = ResultSummary.shortened(damaged[0].lastPathComponent, to: ResultSummary.maxTitleNameLength)
        let title = damaged.count == 1 ? "\(name) can't be read" : "\(damaged.count) files can't be read"
        return WheelAlert(title: title, subtitle: Self.damagedReason(count: damaged.count))
    }

    static func damagedReason(count: Int) -> String {
        count == 1 ? "The file may be damaged" : "The files may be damaged"
    }

    /// The accessibility hint of `slice`: why it is disabled, else what dropping on it makes of the files it would
    /// run on (the readable ones), like the hub's preview.
    func accessibilityHint(for slice: WheelSlice) -> String {
        if let reason = slice.disabledReason { return reason }
        return builder?.preview(for: slice, files: files(toRun: slice, from: files)).title ?? slice.title
    }

    /// The page pill's texts (P32): the key that changes page and the page titles, with no glyph between them.
    struct Pill: Equatable {
        var key: String
        var titles: [String]
    }

    var pill: Pill {
        Pill(key: clickMode ? "⇥" : Self.glyph(of: trigger), titles: pages.map(\.title))
    }

    static func glyph(of trigger: TriggerKey) -> String {
        switch trigger {
        case .shift: "⇧"
        case .option: "⌥"
        case .control: "⌃"
        case .command: "⌘"
        }
    }
}

/// The wheel itself, laid out in the 360×400 panel: the 340 pt ring centred, the page pill in the bottom 30 pt.
struct WheelView: View {
    static let panelSize = CGSize(width: 360, height: 400)
    static let pillBand: CGFloat = 30

    let model: WheelModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let reduceMotion = reduceMotion
        return ZStack {
            ring
                .position(x: Self.panelSize.width / 2, y: Self.panelSize.height / 2)
            if !model.pages.isEmpty {
                pill
                    .position(x: Self.panelSize.width / 2, y: Self.panelSize.height - Self.pillBand / 2)
            }
        }
        .frame(width: Self.panelSize.width, height: Self.panelSize.height)
        .opacity(model.isContentHidden ? 0 : 1)
        // Keyframes rather than a state flip: the animation starts from 0.92 whenever the count changes, however
        // the panel's first frame and the model update interleave.
        .keyframeAnimator(initialValue: Appearance(), trigger: model.openCount) { content, value in
            content
                .scaleEffect(reduceMotion ? 1 : value.scale)
                .opacity(value.opacity)
        } keyframes: { _ in
            KeyframeTrack(\.scale) {
                MoveKeyframe(0.92)
                CubicKeyframe(1, duration: 0.15)
            }
            KeyframeTrack(\.opacity) {
                MoveKeyframe(0)
                CubicKeyframe(1, duration: 0.15)
            }
        }
    }

    private struct Appearance {
        var scale = 1.0
        var opacity = 1.0
    }

    // MARK: - Ring

    private var ring: some View {
        WheelRing(slices: model.slices, hovered: model.hovered, highlightAngle: model.highlightAngle,
                  highlightAnimates: model.highlightAnimates, dimmed: model.dimsSlices, geometry: model.geometry,
                  accessibilityHint: model.accessibilityHint(for:)) {
            hub
        }
    }

    // MARK: - Hub

    private var hub: some View {
        let alert = model.alert
        let tint = Self.tint(of: alert?.style ?? .failure)
        return ZStack {
            // The style's colour as a tint under text in the primary colour: readable in light and dark.
            Circle()
                .fill(tint.opacity(0.2))
                .overlay(Circle().strokeBorder(tint, lineWidth: 2))
                .frame(width: WheelGeometry.defaultHubDiameter, height: WheelGeometry.defaultHubDiameter)
                .opacity(alert == nil ? 0 : 1)
            if let alert {
                alertContent(alert)
            } else {
                previewContent
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: alert)
    }

    private func alertContent(_ alert: WheelAlert) -> some View {
        VStack(spacing: 3) {
            Image(systemName: alert.symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Self.tint(of: alert.style))
            Text(alert.title)
                .font(.headline)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.75)
            if let subtitle = alert.subtitle {
                Text(subtitle)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
        }
        .foregroundStyle(Color.primary)
        .frame(width: 108)
        .accessibilityElement(children: .ignore)
        .modifier(AlertAccessibility(alert: alert, isButton: model.prompt == alert, activate: model.onActivatePrompt))
    }

    /// System red for failures, the accent colour for notes.
    static func tint(of style: WheelAlert.Style) -> Color {
        switch style {
        case .failure: Color(nsColor: .systemRed)
        case .note: Color.accentColor
        }
    }

    /// A prompt's hub reads as a button labelled with its title (the subtitle is the hint); any other alert reads
    /// its title and subtitle.
    private struct AlertAccessibility: ViewModifier {
        let alert: WheelAlert
        let isButton: Bool
        let activate: (() -> Void)?

        func body(content: Content) -> some View {
            if isButton {
                content
                    .accessibilityLabel(alert.title)
                    .accessibilityHint(alert.subtitle ?? "")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { activate?() }
            } else {
                content.accessibilityLabel(alert.subtitle.map { "\(alert.title). \($0)" } ?? alert.title)
            }
        }
    }

    private var previewContent: some View {
        let preview = model.preview
        // A disabled slice's reason names what to install, and the command must not be cut off.
        let showsReason = model.hovered.flatMap { model.slices[$0].disabledReason } != nil
        return VStack(spacing: 2) {
            if let thumbnail = model.thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 48, height: 48)
            }
            Text(preview.title)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
                .minimumScaleFactor(0.75)
            if let subtitle = preview.subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(showsReason ? 3 : 2)
                    .minimumScaleFactor(0.8)
            }
            if let warning = preview.warning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(width: 108)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(preview.subtitle.map { "\(preview.title). \($0)" } ?? preview.title)
    }

    // MARK: - Page pill

    private var pill: some View {
        let pill = model.pill
        return KeyPill(key: pill.key, titles: pill.titles, current: model.pageIndex)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(model.page.map {
                "\($0.title) page, \(model.pageIndex + 1) of \(model.pages.count)"
            } ?? "")
    }
}

/// The key in its little box, then the titles with the current one bright (P32: separate labels, nothing between
/// them): the wheel's page pill, and the Shelf's ⌘ pill (R30).
struct KeyPill: View {
    let key: String
    let titles: [String]
    let current: Int

    var body: some View {
        HStack(spacing: 10) {
            Text(key)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 4)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.secondary, lineWidth: 0.5))
            ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                Text(title)
                    .fontWeight(index == current ? .semibold : .regular)
                    .foregroundStyle(index == current ? .primary : .secondary)
            }
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .wheelBackground(in: Capsule())
    }
}

/// Quick Look thumbnails for the hub.
enum WheelThumbnail {
    static let side: CGFloat = 48

    /// The best thumbnail of `url` at `side` points, or nil when Quick Look has none.
    static func load(for url: URL, scale: CGFloat) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: side, height: side), scale: scale, representationTypes: .all
        )
        guard let cgImage = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage
        else { return nil }
        return NSImage(cgImage: cgImage, size: CGSize(width: side, height: side))
    }

    /// The file-type icon, shown until the thumbnail arrives.
    static func placeholder(for url: URL) -> NSImage {
        NSWorkspace.shared.icon(forFile: url.path)
    }
}
