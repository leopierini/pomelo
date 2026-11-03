// Customized wheels (P175, P176, P178): which wheel a drag opens, and a customized wheel's slots resolved in place.
// A slot never moves or hides: one that can't work for these files is greyed with a sentence saying why (P32). Also
// what the wheel editor draws and offers (P179). Slots plan over the same route cache as the built-in pages (P181).
import Foundation
import PomeloCore

/// What can go on a wheel, as the editor's chip groups.
public struct WheelCandidates: Equatable, Sendable {
    public var convert, tools, ai, fileTools: [WheelSlice]
}

extension WheelContentBuilder {
    public static let unavailableReason = "Not available."

    // MARK: - Which wheel (P175)

    /// The customized wheel the files' formats open, nil for a built-in one: the format's own wheel when every file is
    /// in that format, else the kind's when every file is of that kind. An unknown file or a folder is kind `other`.
    func wheelKey(forFormats fileFormats: [FileFormat?]) -> WheelKey? {
        guard !wheels.isEmpty, let first = fileFormats.first else { return nil }
        if let format = first, fileFormats.allSatisfy({ $0?.id == format.id }),
           wheels[WheelKey.format(format.id).rawValue] != nil {
            return .format(format.id)
        }
        let kind = first?.category ?? .other
        guard fileFormats.allSatisfy({ ($0?.category ?? .other) == kind }),
              wheels[WheelKey.kind(kind).rawValue] != nil else { return nil }
        return .kind(kind)
    }

    // MARK: - Slots

    /// What a slot id names, while it still names something this builder offers.
    private enum Slot {
        case convert(FileFormat)
        case tool(ToolInfo, Preset)
        case action(ToolInfo, FileActionKind)
    }

    /// Nil for an id that no longer resolves: a format the registry doesn't know, a tool the catalog dropped or this
    /// builder doesn't offer, or a prefix that doesn't match the tool (P178).
    private func slot(_ id: String) -> Slot? {
        guard let dot = id.firstIndex(of: ".") else { return nil }
        let name = String(id[id.index(after: dot)...])
        switch id[..<dot] {
        case "convert":
            return formats.format(id: FormatID(name)).map(Slot.convert)
        case "preset", "editor":
            guard let info = ToolCatalog.info(name), info.action == nil, let preset = tools[name],
                  Self.slotID(of: info) == id else { return nil }
            return .tool(info, preset)
        case "action":
            return FileActionKind(rawValue: name).map { .action(ToolCatalog.info(for: $0), $0) }
        default:
            return nil
        }
    }

    /// The slot's slice as the wheel titles and symbols it, enabled.
    private func slice(for slot: Slot) -> WheelSlice {
        switch slot {
        case .convert(let format):
            makeSlice(target: format.id, isEnabled: true, reason: nil, routes: [])
        case .tool(let info, let preset):
            WheelSlice(id: Self.slotID(of: info), title: preset.name, symbol: info.symbol,
                       kind: info.editor == nil ? .preset(id: preset.id) : .editor(id: preset.id))
        case .action(let info, let action):
            WheelSlice(id: Self.slotID(of: info), title: info.name, symbol: info.symbol, kind: .action(action))
        }
    }

    /// A slot whose id no longer resolves keeps its place, greyed (P178). It does nothing on a drop, whatever its kind.
    private func unavailableSlice(_ id: String) -> WheelSlice {
        let name = id.firstIndex(of: ".").map { String(id[id.index(after: $0)...]) } ?? id
        if id.hasPrefix("convert."), !name.isEmpty {
            return makeSlice(target: FormatID(name), isEnabled: false, reason: Self.unavailableReason, routes: [])
        }
        return WheelSlice(id: id, title: ToolCatalog.info(name)?.name ?? (name.isEmpty ? id : name),
                          symbol: ToolCatalog.symbol(ofPreset: name), kind: .preset(id: name), isEnabled: false,
                          disabledReason: Self.unavailableReason)
    }

    // MARK: - Customized pages (P176)

    /// The dragged files, as every slot of a customized wheel needs them.
    private struct SlotDrag {
        let files: [URL]
        let formats: [FileFormat?]
        /// Empty when a file's format is unknown: nothing that needs an engine can run then.
        let plans: [SourcePlan]
        let kinds: Set<FormatCategory>
        let folders: Int
    }

    /// Every page with a slot, each slot where the user put it; a page whose slots are all greyed is still shown.
    func customPages(_ wheel: CustomWheel, for files: [URL], formats fileFormats: [FileFormat?]) -> [WheelPage] {
        let sources = fileFormats.compactMap { $0 }
        let drag = SlotDrag(files: files, formats: fileFormats,
                            plans: sources.count == files.count ? plan(sources) : [],
                            kinds: Set(fileFormats.map { $0?.category ?? .other }),
                            folders: Self.folderCount(of: files))
        return wheel.pages.enumerated().compactMap { index, page in
            guard !page.slots.isEmpty else { return nil }
            return WheelPage(customIndex: index, name: page.name, slices: page.slots.map { resolve($0, for: drag) })
        }
    }

    /// The reasons, first match wins: the id doesn't resolve; the number of files or their folders; every file is
    /// already in the target; no route over every engine; a route only over engines this Mac lacks or can't run.
    private func resolve(_ id: String, for drag: SlotDrag) -> WheelSlice {
        guard let slot = slot(id) else { return unavailableSlice(id) }
        switch slot {
        case .convert(let target):
            return convertSlice(to: target, for: drag)
        case .tool(let info, let preset):
            return toolSlice(info: info, preset: preset, for: drag)
        case .action(let info, _):
            let base = slice(for: slot)
            return blockReason(info, preset: nil, for: drag).map(base.greyed) ?? base
        }
    }

    private func convertSlice(to target: FileFormat, for drag: SlotDrag) -> WheelSlice {
        let converting = drag.formats.count { $0?.id != target.id }
        guard converting > 0 else {
            return slice(for: .convert(target)).greyed(Self.alreadyReason(target.displayName, files: drag.files.count))
        }
        let pending = drag.plans.filter { $0.format.id != target.id }
        let fullRoutes = pending.map { $0.allTargets[target.id] }
        guard !drag.plans.isEmpty, fullRoutes.allSatisfy({ $0 != nil }) else {
            return slice(for: .convert(target))
                .greyed(converting == 1 ? "Can't convert this file." : "Can't convert these files.")
        }
        let routes = pending.map { $0.availableTargets[target.id] }
        if routes.allSatisfy({ $0 != nil }) {
            return makeSlice(target: target.id, isEnabled: true, reason: nil, routes: routes.compactMap { $0 })
        }
        let missing = zip(routes, fullRoutes).first { $0.0 == nil }?.1
        return makeSlice(target: target.id, isEnabled: false, reason: reason(for: missing),
                         routes: fullRoutes.compactMap { $0 })
    }

    /// P183 (amended, ruling 17): "Already an AVIF file." for one file, "Already PNG files." for several. "an" before
    /// a vowel, and before an initialism whose first letter is read with one (an MP4, an SVG, an RTF, an HTML).
    private static func alreadyReason(_ name: String, files: Int) -> String {
        guard files == 1 else { return "Already \(name) files." }
        guard let first = name.first else { return "Already a \(name) file." }
        let isInitialism = name.allSatisfy { $0.isUppercase || $0.isNumber }
        let vowelSound = "AEIO".contains(first.uppercased())
            || (isInitialism && ("MNRSX".contains(first) || name.hasPrefix("HT")))
        return "Already \(vowelSound ? "an" : "a") \(name) file."
    }

    /// The built-in wheel's rules (`blockReason`) first, then the routes. A slot greyed by a rule keeps its routes'
    /// flags when it has routes, as the built-in slice would.
    private func toolSlice(info: ToolInfo, preset: Preset, for drag: SlotDrag) -> WheelSlice {
        let suitsKinds = info.kinds.map { drag.kinds.isSubset(of: $0) } ?? true
        let routed = suitsKinds && !drag.plans.isEmpty
            ? engineToolSlice(info: info, preset: preset, plans: drag.plans) : nil
        let base = routed ?? slice(for: .tool(info, preset))
        if let reason = blockReason(info, preset: preset, for: drag) { return base.greyed(reason) }
        return routed ?? base.greyed(Self.doesNotWorkReason(files: drag.files.count))
    }

    private func blockReason(_ info: ToolInfo, preset: Preset?, for drag: SlotDrag) -> String? {
        Self.blockReason(info: info, preset: preset, files: drag.files.count, kinds: drag.kinds, folders: drag.folders)
    }

    // MARK: - The editor (P179)

    /// The pages as the editor draws them, with no files: every page, empty ones included, so they can be filled.
    public func editorPages(for wheel: CustomWheel) -> [WheelPage] {
        wheel.pages.enumerated().map { index, page in
            WheelPage(customIndex: index, name: page.name,
                      slices: page.slots.map { id in slot(id).map(slice(for:)) ?? unavailableSlice(id) })
        }
    }

    /// The kind's formats: those in the kind's order first, in that order, then by display name.
    public func formats(of kind: FormatCategory) -> [FileFormat] {
        let preferred = order[kind] ?? []
        return formats.all.filter { $0.category == kind }.sorted { a, b in
            (preferred.firstIndex(of: a.id) ?? .max, a.displayName, a.id.rawValue)
                < (preferred.firstIndex(of: b.id) ?? .max, b.displayName, b.id.rawValue)
        }
    }

    /// Every registered format `plans` reach over every engine: `category`'s order first, then by display name.
    private func conversionTargets(from plans: [SourcePlan], category: FormatCategory) -> [FileFormat] {
        let reachable = plans.reduce(into: Set<FormatID>()) { $0.formUnion($1.allTargets.keys) }
        let preferred = (order[category] ?? []).filter(reachable.contains)
        let listed = Set(preferred)
        let rest = reachable.subtracting(listed).compactMap { formats.format(id: $0) }
            .sorted { ($0.displayName, $0.id.rawValue) < ($1.displayName, $1.id.rawValue) }
        return preferred.compactMap { formats.format(id: $0) } + rest
    }

    /// What a built-in wheel shows by default, as the first edit copies it: Convert, the kind's top targets; Tools and
    /// AI, the tools the kind shows (the user's switches included) for one file or several, in catalog order, so
    /// Merge PDFs is on the copy and greys for one PDF. Empty pages are left out, and AI too when none of its tools
    /// runs on this Mac from a format of the kind, as the built-in wheel leaves it out (P185).
    public func builtInLayout(for kind: FormatCategory) -> CustomWheel {
        let plans = plan(formats(of: kind))
        let convert = conversionTargets(from: plans, category: kind).prefix(Self.maxSlices)
            .map { Self.slotID(convertingTo: $0.id) }
        func shownTools(ai: Bool) -> [String] {
            let ids = ToolCatalog.all.filter { info in
                info.isAI == ai && (info.kinds?.contains(kind) ?? true) && visibility.isShown(info.id, for: kind)
            }.map(Self.slotID(of:)).filter { slot($0) != nil }
            // The Shelf keeps the last slot, as the built-in wheel shows it (R27).
            let shelf = Self.slotID(of: ToolCatalog.info(for: .shelf))
            guard ids.contains(shelf) else { return Array(ids.prefix(ToolCatalog.maxShownPerKind)) }
            return ids.filter { $0 != shelf }.prefix(ToolCatalog.maxShownPerKind - 1) + [shelf]
        }
        let ai = shownTools(ai: true)
        let aiRuns = ai.contains { id in
            guard case .tool(_, let preset) = slot(id) else { return false }
            return plans.contains { availableRoute(for: preset, from: $0) != nil }
        }
        let pages: [(WheelPageKind, [String])] = [
            (.convert, Array(convert)), (.tools, shownTools(ai: false)), (.ai, aiRuns ? ai : []),
        ]
        return CustomWheel(pages: pages.filter { !$0.1.isEmpty }.map { CustomPage(name: $0.0.title, slots: $0.1) })
    }

    /// Everything that applies to the wheel, enabled, as the wheel titles it: for a kind, the targets any of its
    /// formats reaches and the tools whose kinds include it; for a format, its own targets and its kind's tools.
    public func candidates(for key: WheelKey) -> WheelCandidates {
        let sources: [FileFormat]
        let kind: FormatCategory
        switch key {
        case .kind(let category):
            sources = formats(of: category)
            kind = category
        case .format(let id):
            sources = formats.format(id: id).map { [$0] } ?? []
            kind = sources.first?.category ?? .other
        }
        let applicable = ToolCatalog.all.filter { $0.kinds?.contains(kind) ?? true }
        func slices(_ infos: [ToolInfo]) -> [WheelSlice] {
            infos.compactMap { slot(Self.slotID(of: $0)).map(slice(for:)) }
        }
        return WheelCandidates(
            convert: conversionTargets(from: plan(sources), category: kind).map { slice(for: .convert($0)) },
            tools: slices(applicable.filter { $0.action == nil && !$0.isAI }),
            ai: slices(applicable.filter(\.isAI)),
            fileTools: slices(applicable.filter { $0.action != nil })
        )
    }
}

extension WheelSlice {
    fileprivate func greyed(_ reason: String) -> WheelSlice {
        var slice = self
        slice.isEnabled = false
        slice.disabledReason = reason
        return slice
    }
}
