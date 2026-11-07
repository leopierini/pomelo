// Pure content of the conversion wheel: which slices each page shows for a set of files, which are disabled and
// why (an engine this Mac can't run, or a missing engine plus its install hint), and the text the hub previews
// while a slice is hovered.
// Only Foundation and PomeloCore: no AppKit.
import Foundation
import os
import PomeloCore

/// The wheel's pages, in the order the user cycles through them (P31).
public enum WheelPageKind: String, Codable, Sendable, CaseIterable {
    case convert, tools, ai

    public var title: String {
        switch self {
        case .convert: "Convert"
        case .tools: "Tools"
        case .ai: "AI"
        }
    }
}

/// A file tool: it works on the dragged files themselves and needs no engine.
public enum FileActionKind: String, Codable, Sendable, CaseIterable {
    case copyPaths, copyFiles, revealInFinder, makeZip, openTerminal, shelf
}

/// What a slice does when a drop lands on it.
public enum SliceKind: Equatable, Sendable {
    case convert(FormatID)
    case preset(id: String)
    /// A tool that opens an editor at the drop point instead of running (P27, P31).
    case editor(id: String)
    case action(FileActionKind)
}

public struct WheelSlice: Equatable, Sendable, Identifiable {
    /// `convert.<format>`, `preset.<id>`, `editor.<id>` or `action.<kind>`.
    public var id: String
    public var title: String
    /// An SF Symbol name.
    public var symbol: String
    public var kind: SliceKind
    public var isEnabled: Bool
    /// Why a disabled slice is disabled, e.g. `Needs cwebp. Install it with brew install webp.`
    public var disabledReason: String?
    /// The union of the flags of the routes the slice would run.
    public var flags: EdgeFlags

    public init(id: String, title: String, symbol: String, kind: SliceKind, isEnabled: Bool = true,
                disabledReason: String? = nil, flags: EdgeFlags = []) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.kind = kind
        self.isEnabled = isEnabled
        self.disabledReason = disabledReason
        self.flags = flags
    }
}

public struct WheelPage: Equatable, Sendable {
    /// The built-in kind's raw value, else `custom.<index>`: what the wheel matches a page by.
    public var id: String
    public var title: String
    /// Nil for a page the user made.
    public var kind: WheelPageKind?
    public var slices: [WheelSlice]

    public init(kind: WheelPageKind, slices: [WheelSlice]) {
        self.id = kind.rawValue
        self.title = kind.title
        self.kind = kind
        self.slices = slices
    }

    public init(customIndex: Int, name: String, slices: [WheelSlice]) {
        self.id = "custom.\(customIndex)"
        self.title = name
        self.kind = nil
        self.slices = slices
    }
}

/// The hub's text for a hovered slice.
public struct HubPreview: Equatable, Sendable {
    public var title: String
    public var subtitle: String?
    public var warning: String?

    public init(title: String, subtitle: String? = nil, warning: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.warning = warning
    }
}

/// Decides the wheel's pages and hub text for a set of files.
///
/// `available` plans over the engines that are installed, `all` over every known engine. A conversion that only
/// `all` can route shows as a disabled slice: the reason of the first unsupported engine on its route, else the
/// first missing engine's install hint.
public struct WheelContentBuilder: Sendable {
    public static let maxSlices = 8

    /// The formats each source category offers first, in this order: measured demand first (P194). A disabled
    /// target shows only through this list, so a presentation's jpg and png (P201) are in it.
    public static let defaultOrder: [FormatCategory: [FormatID]] = [
        .image: ["jpg", "png", "pdf", "txt", "gif", "ico", "webp", "heic"],
        .video: ["mp4", "gif", "mp3", "mov", "wav", "m4a", "webm", "avi"],
        .audio: ["mp3", "wav", "m4a", "ogg", "flac", "aiff", "opus"],
        .pdf: ["docx", "jpg", "png", "txt"],
        .document: ["csv", "pdf", "jpg", "png", "docx", "doc", "epub", "txt", "html", "odt", "rtf"],
        .data: ["xlsx"],
        .text: ["pdf", "docx", "html", "rtf", "md", "odt"],
        .archive: ["zip", "tgz", "tar"],
        .subtitle: ["vtt", "srt"],
    ]

    public static let layoutWarning = "Layout may shift"
    public static let replaceWarning = "Replaces the original"
    public static let multiPageHint = "One image per page"

    let formats: FormatRegistry
    private let available: RoutePlanner
    private let all: RoutePlanner
    private let installHints: [EngineID: String]
    private let unsupportedReasons: [EngineID: String]
    private let installable: Set<EngineID>
    let order: [FormatCategory: [FormatID]]
    let tools: [String: Preset]
    let visibility: ToolVisibility
    private let replacesOriginals: Bool
    /// `WheelKey.rawValue` → the user's wheel (P180).
    let wheels: [String: CustomWheel]
    private let routeCache = RouteCache()

    /// `tools` are the engine tools to offer, as `ToolCatalog.presets(settings:)` makes them: a catalog tool with
    /// no preset here is not offered.
    public init(formats: FormatRegistry, available: RoutePlanner, all: RoutePlanner, installHints: [EngineID: String],
                unsupportedReasons: [EngineID: String] = [:], installable: Set<EngineID> = [],
                order: [FormatCategory: [FormatID]] = WheelContentBuilder.defaultOrder, tools: [Preset],
                visibility: ToolVisibility = .defaults, replacesOriginals: Bool = false,
                wheels: [String: CustomWheel] = [:]) {
        self.formats = formats
        self.available = available
        self.all = all
        self.installHints = installHints
        self.unsupportedReasons = unsupportedReasons
        self.installable = installable
        self.order = order
        self.tools = Dictionary(tools.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.visibility = visibility
        self.replacesOriginals = replacesOriginals
        self.wheels = wheels
    }

    /// The configured engine tool `id`, with the user's options.
    public func tool(id: String) -> Preset? { tools[id] }

    // MARK: - Symbols

    /// The symbol of a conversion, by the category of its target.
    public static func symbol(forTarget category: FormatCategory) -> String {
        switch category {
        case .image: "photo"
        case .video: "film"
        case .audio: "waveform"
        default: "doc"
        }
    }

    // MARK: - Pages

    /// The pages for `files`: the user's wheel when P175 picks one, else the built-in Convert, Tools, then AI. Empty
    /// built-in pages are left out, and AI only appears with a tool that can run.
    public func pages(for files: [URL]) -> [WheelPage] {
        guard !files.isEmpty else { return [] }
        let fileFormats = files.map { formats.format(for: $0) }
        if let key = wheelKey(forFormats: fileFormats), let wheel = wheels[key.rawValue] {
            return customPages(wheel, for: files, formats: fileFormats)
        }
        let sources = fileFormats.compactMap { $0 }
        let plans = sources.count == files.count ? plan(sources) : []
        var pages: [WheelPage] = []
        let convert = convertSlices(for: plans)
        if !convert.isEmpty { pages.append(WheelPage(kind: .convert, slices: convert)) }
        let kinds = Set(fileFormats.map { $0?.category ?? .other })
        let tools = toolSlices(for: files, kinds: kinds, plans: plans, ai: false)
        if !tools.isEmpty { pages.append(WheelPage(kind: .tools, slices: tools)) }
        let intelligence = toolSlices(for: files, kinds: kinds, plans: plans, ai: true)
        if intelligence.contains(where: \.isEnabled) { pages.append(WheelPage(kind: .ai, slices: intelligence)) }
        return pages
    }

    /// The routes from one source format, planned once however many dragged files share it.
    struct SourcePlan {
        let format: FileFormat
        /// How many of the dragged files are in this format.
        let count: Int
        /// The best route to every other format, over every engine and over the installed ones.
        let allTargets: [FormatID: Route]
        let availableTargets: [FormatID: Route]
        /// The self-edges, for tools that keep the format.
        let allSelf: Route?
        let availableSelf: Route?

        init(format: FileFormat, count: Int, routes: FormatRoutes) {
            self.format = format
            self.count = count
            var all = routes.all
            allSelf = all.removeValue(forKey: format.id)
            allTargets = all
            var available = routes.available
            availableSelf = available.removeValue(forKey: format.id)
            availableTargets = available
        }

        func available(to target: FormatID) -> Route? {
            target == format.id ? availableSelf : availableTargets[target]
        }
    }

    /// Every route from one format, over every engine and over the installed ones.
    struct FormatRoutes: Sendable {
        let all: [FormatID: Route]
        let available: [FormatID: Route]
    }

    /// The route searches were most of `WheelController.open` (Phase 6 profile), so each format is searched once per
    /// builder. The app makes a new builder whenever engines, plugins or settings change, which is what empties this.
    final class RouteCache: Sendable {
        private let state = OSAllocatedUnfairLock(initialState: (routes: [FormatID: FormatRoutes](), searches: 0))

        var searches: Int { state.withLock { $0.searches } }

        func routes(from format: FormatID, search: () -> FormatRoutes) -> FormatRoutes {
            if let known = state.withLock({ $0.routes[format] }) { return known }
            let found = search()
            state.withLock {
                $0.routes[format] = found
                $0.searches += 1
            }
            return found
        }
    }

    /// How many formats this builder has searched routes from; for the tests.
    var routeSearches: Int { routeCache.searches }

    /// One plan per distinct source format, in the order the formats first appear. Each route search is an
    /// exhaustive walk, so a drag of hundreds of files of a few formats must not search once per file.
    func plan(_ sources: [FileFormat]) -> [SourcePlan] {
        var order: [FileFormat] = []
        var counts: [FormatID: Int] = [:]
        for source in sources {
            if counts[source.id] == nil { order.append(source) }
            counts[source.id, default: 0] += 1
        }
        return order.map { format in
            let routes = routeCache.routes(from: format.id) {
                FormatRoutes(all: all.routes(from: format.id), available: available.routes(from: format.id))
            }
            return SourcePlan(format: format, count: counts[format.id]!, routes: routes)
        }
    }

    private func convertSlices(for plans: [SourcePlan]) -> [WheelSlice] {
        guard let first = plans.first else { return [] }
        // A target is a candidate when every file already is it or reaches it, and at least one file still
        // needs converting (so a lone PNG gets no PNG slice, but PNG + JPG gets a JPG one).
        var possible = Set(plans.map(\.format.id))
        for plan in plans { possible.formUnion(plan.allTargets.keys) }
        let candidates = possible.filter { target in
            plans.allSatisfy { $0.format.id == target || $0.allTargets[target] != nil }
                && plans.contains { $0.format.id != target }
        }

        var slices: [FormatID: WheelSlice] = [:]
        var enabledCost: [FormatID: Int] = [:]
        for target in candidates {
            let pending = plans.filter { $0.format.id != target }
            let routes = pending.map { $0.availableTargets[target] }
            if routes.allSatisfy({ $0 != nil }) {
                let used = routes.compactMap { $0 }
                slices[target] = makeSlice(target: target, isEnabled: true, reason: nil, routes: used)
                // Every file runs its route, so a format's route counts once per file in it.
                enabledCost[target] = zip(pending, used).reduce(0) { $0 + $1.0.count * $1.1.totalCost }
            } else {
                let missing = zip(pending, routes).first { $0.1 == nil }!.0
                let used = pending.compactMap { $0.allTargets[target] }
                slices[target] = makeSlice(target: target, isEnabled: false, reason: reason(for: missing.allTargets[target]),
                                           routes: used)
            }
        }

        let preferred = (order[first.format.category] ?? []).filter { slices[$0] != nil }
        let listed = Set(preferred)
        let rest = enabledCost.keys.filter { !listed.contains($0) }
            .sorted { (enabledCost[$0]!, $0.rawValue) < (enabledCost[$1]!, $1.rawValue) }
        return (preferred + rest).prefix(Self.maxSlices).compactMap { slices[$0] }
    }

    func makeSlice(target: FormatID, isEnabled: Bool, reason: String?, routes: [Route]) -> WheelSlice {
        let format = formats.format(id: target)
        return WheelSlice(
            id: Self.slotID(convertingTo: target),
            title: format?.displayName ?? target.rawValue.uppercased(),
            symbol: Self.symbol(forTarget: format?.category ?? .other),
            kind: .convert(target), isEnabled: isEnabled, disabledReason: reason,
            flags: routes.reduce(into: []) { $0.formUnion($1.flags) }
        )
    }

    /// The reason of the first engine on `route` this Mac can't run, verbatim: installing another engine wouldn't
    /// help. Else a sentence naming the first engine that has an install hint (`"<name>|<hint>"`), P32.
    func reason(for route: Route?) -> String {
        guard let route else { return Self.unavailableReason }
        if let reason = route.edges.lazy.compactMap({ unsupportedReasons[$0.engineID] }).first { return reason }
        guard let engine = route.edges.map(\.engineID).first(where: { installHints[$0] != nil }),
              let value = installHints[engine] else { return Self.unavailableReason }
        let parts = value.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        return Self.missingEngineReason(name: parts[0], hint: parts.count == 2 ? parts[1] : nil,
                                        installable: installable.contains(engine))
    }

    /// "Needs cwebp. Install it from Pomelo's Settings." when Pomelo can download it (P114), else "Needs cwebp.
    /// Install it with brew install webp." for a Homebrew hint, "Needs X. Get it from <url>." for a website, "Needs
    /// cwebp." when the hint is only CommandEngine's fallback ("Install <name>") or missing.
    static func missingEngineReason(name: String, hint: String?, installable: Bool) -> String {
        if installable { return "Needs \(name). Install it from Pomelo's Settings." }
        let hint = hint?.trimmingCharacters(in: .whitespaces) ?? ""
        if hint.hasPrefix("brew install") { return "Needs \(name). Install it with \(hint)." }
        if hint.isEmpty || hint.hasPrefix("Install ") { return "Needs \(name)." }
        return "Needs \(name). Get it from \(hint)."
    }

    /// The tools of one page (`ai` picks the AI tools) that apply to every file of the drag, in catalog order and
    /// capped at `ToolCatalog.maxShownPerKind`: an engine tool or editor when every kind in the drag shows it, a file
    /// tool when one kind does (P61). A tool `blockReason` refuses is left out. `plans` is empty when a file's format
    /// is unknown, which leaves only file tools. A shown Shelf keeps the last slot (R27).
    private func toolSlices(for files: [URL], kinds: Set<FormatCategory>, plans: [SourcePlan],
                            ai: Bool) -> [WheelSlice] {
        let parents = Self.folderCount(of: files)
        func slice(_ info: ToolInfo) -> WheelSlice? {
            let shown = info.action == nil
                ? kinds.allSatisfy { visibility.isShown(info.id, for: $0) }
                : kinds.contains { visibility.isShown(info.id, for: $0) }
            let preset = info.action == nil ? tools[info.id] : nil
            guard shown, Self.blockReason(info: info, preset: preset, files: files.count, kinds: kinds,
                                          folders: parents) == nil else { return nil }
            if let action = info.action {
                return WheelSlice(id: Self.slotID(of: info), title: info.name, symbol: info.symbol, kind: .action(action))
            }
            guard let preset, !plans.isEmpty else { return nil }
            return engineToolSlice(info: info, preset: preset, plans: plans)
        }
        let shelf = ai ? nil : slice(ToolCatalog.info(for: .shelf))
        let room = ToolCatalog.maxShownPerKind - (shelf == nil ? 0 : 1)
        var slices: [WheelSlice] = []
        for info in ToolCatalog.all where info.isAI == ai && info.action != .shelf {
            if slices.count == room { break }
            if let slice = slice(info) { slices.append(slice) }
        }
        return slices + (shelf.map { [$0] } ?? [])
    }

    /// Why `info` can't work on these files whatever the engines, nil when only its routes decide: the one set of
    /// rules (P61) the built-in wheel leaves a tool out by and a customized one greys a slot with (P176). First match
    /// wins, in this order.
    static func blockReason(info: ToolInfo, preset: Preset?, files: Int, kinds: Set<FormatCategory>,
                            folders: Int) -> String? {
        if info.action == .openTerminal && folders != 1 { return "Needs files from one folder." }
        if !info.acceptsSeveralFiles && files > 1 { return "Needs one file." }
        if preset?.combinesInputs == true && files < 2 { return "Needs two or more files." }
        let suitsKinds = info.kinds.map { kinds.isSubset(of: $0) } ?? true
        if !suitsKinds || (info.editor != nil && kinds.count != 1) { return doesNotWorkReason(files: files) }
        return nil
    }

    static func doesNotWorkReason(files: Int) -> String {
        files == 1 ? "Doesn't work on this file." : "Doesn't work on these files."
    }

    /// How many folders the files are in.
    static func folderCount(of files: [URL]) -> Int {
        Set(files.map { $0.deletingLastPathComponent().standardizedFileURL.path }).count
    }

    // MARK: - Slot ids

    /// The id of a slice converting to `target`, as slices have it and a customized wheel stores it (P180).
    static func slotID(convertingTo target: FormatID) -> String { "convert.\(target.rawValue)" }

    /// `action.<kind>` for a file tool, `editor.<id>` for an editor, else `preset.<id>`.
    static func slotID(of info: ToolInfo) -> String {
        if let action = info.action { return "action.\(action.rawValue)" }
        return "\(info.editor == nil ? "preset" : "editor").\(info.id)"
    }

    /// An `editor.<id>` slice for an editor, else a `preset.<id>` one. Enabled when every source format routes over
    /// the installed engines, disabled (naming the first missing engine) when only the full graph routes them all,
    /// nil when some format has no route at all.
    func engineToolSlice(info: ToolInfo, preset: Preset, plans: [SourcePlan]) -> WheelSlice? {
        let routes = plans.map { availableRoute(for: preset, from: $0) }
        let id = Self.slotID(of: info)
        let kind: SliceKind = info.editor != nil ? .editor(id: preset.id) : .preset(id: preset.id)
        if routes.allSatisfy({ $0 != nil }) {
            return WheelSlice(id: id, title: preset.name, symbol: info.symbol, kind: kind,
                              flags: Self.flags(of: routes.compactMap { $0 }))
        }
        let fullRoutes = plans.map { allRoute(for: preset, from: $0) }
        guard fullRoutes.allSatisfy({ $0 != nil }),
              let missing = zip(routes, fullRoutes).first(where: { $0.0 == nil })?.1 else { return nil }
        return WheelSlice(id: id, title: preset.name, symbol: info.symbol, kind: kind,
                          isEnabled: false, disabledReason: reason(for: missing),
                          flags: Self.flags(of: fullRoutes.compactMap { $0 }))
    }

    func availableRoute(for preset: Preset, from plan: SourcePlan) -> Route? {
        if let operation = preset.operation {
            return available.route(from: plan.format.id, operation: operation, to: preset.target)
        }
        return plan.available(to: preset.target ?? plan.format.id)
    }

    private func allRoute(for preset: Preset, from plan: SourcePlan) -> Route? {
        if let operation = preset.operation {
            return all.route(from: plan.format.id, operation: operation, to: preset.target)
        }
        let target = preset.target ?? plan.format.id
        return target == plan.format.id ? plan.allSelf : plan.allTargets[target]
    }

    private static func flags(of routes: [Route]) -> EdgeFlags {
        routes.reduce(into: []) { $0.formUnion($1.flags) }
    }

    // MARK: - Hub preview

    /// The files a convert slice to `target` actually converts: those not already in that format.
    /// The job coordinator passes only these to the runner.
    public func filesToConvert(_ files: [URL], to target: FormatID) -> [URL] {
        files.filter { formats.format(for: $0)?.id != target }
    }

    /// What the pill says while `files` convert to `target` (P25): text recognition reads differently from a
    /// conversion. Decided by the first file's route, planned once when the job starts.
    public func conversionVerb(for files: [URL], to target: FormatID) -> String {
        guard let source = files.first.flatMap({ formats.format(for: $0) }),
              let route = available.route(from: source.id, to: target) else { return "Converting" }
        return route.edges.last?.engineID == "vision" ? "Recognizing text" : "Converting"
    }

    /// The hub text for hovering `slice` while dragging `files`. Convert previews count and name only the files
    /// that need converting. The subtitle is the disabled reason, else the multi-page hint, else the size estimate
    /// from `facts`.
    public func preview(for slice: WheelSlice, files: [URL], facts: [URL: SourceFacts] = [:]) -> HubPreview {
        var warning = slice.flags.contains(.layoutRisk) ? Self.layoutWarning : nil
        guard case .convert(let target) = slice.kind else {
            if case .editor(let id) = slice.kind {
                if replacesOriginals, slice.isEnabled, ToolCatalog.info(id)?.canReplaceOriginal == true {
                    warning = Self.replaceWarning
                }
                return HubPreview(title: slice.title, subtitle: slice.disabledReason ?? ToolCatalog.info(id)?.hint,
                                  warning: warning)
            }
            if replacesOriginals, slice.isEnabled, case .preset(let id) = slice.kind,
               ToolCatalog.info(id)?.canReplaceOriginal == true {
                warning = Self.replaceWarning
            }
            return HubPreview(title: slice.title,
                              subtitle: slice.disabledReason ?? estimateText(for: slice, files: files, facts: facts),
                              warning: warning)
        }
        let converted = filesToConvert(files, to: target)
        // A customized wheel's own-format slot (P176) converts nothing: "0 files → PNG" would say nothing.
        if converted.isEmpty {
            return HubPreview(title: slice.title, subtitle: slice.disabledReason, warning: warning)
        }
        // As the runner decides (P273): a conversion that keeps the kind of file replaces its source.
        let targetCategory = formats.format(id: target)?.category
        if replacesOriginals, slice.isEnabled, targetCategory != nil, targetCategory != .other,
           converted.contains(where: { formats.format(for: $0)?.category == targetCategory }) {
            warning = Self.replaceWarning
        }
        let ext = formats.format(id: target)?.extensions.first ?? target.rawValue
        let title = converted.count == 1
            ? "\(OutputNamer.stem(of: converted[0])).\(ext)"
            : "\(converted.count) files → \(ext.uppercased())"
        var subtitle = slice.disabledReason
        if subtitle == nil, formats.format(id: target)?.category == .image,
           converted.contains(where: { formats.format(for: $0)?.category == .pdf }) {
            subtitle = Self.multiPageHint
        }
        if subtitle == nil { subtitle = estimateText(for: slice, files: converted, facts: facts) }
        return HubPreview(title: title, subtitle: subtitle, warning: warning)
    }

    /// The size estimate for `slice` over `files` (those it runs on), when every file has the facts its rule needs.
    private func estimateText(for slice: WheelSlice, files: [URL], facts: [URL: SourceFacts]) -> String? {
        guard slice.isEnabled, !facts.isEmpty else { return nil }
        let target: FormatID?
        let preset: Preset?
        switch slice.kind {
        case .convert(let format):
            target = format
            preset = nil
        case .preset(let id):
            guard let configured = tools[id] else { return nil }
            target = configured.target
            preset = configured
        case .action, .editor:
            return nil
        }
        var sources: [(format: FileFormat, facts: SourceFacts)] = []
        for file in files {
            guard let format = formats.format(for: file), let fileFacts = facts[file] else { return nil }
            sources.append((format, fileFacts))
        }
        return SizeEstimate.estimate(target: target, preset: preset, sources: sources)
            .map { SizeEstimate.text(estimate: $0.estimate, source: $0.source) }
    }
}
