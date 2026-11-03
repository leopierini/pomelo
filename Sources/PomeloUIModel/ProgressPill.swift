// The progress pill's pure model (P25): one pill per job near the drop point, shown only for long jobs and never
// while the wheel still holds the job. It amends P23: a pill is progress, a failure the hub did not show, or a
// short note, never a success. Text follows P32: the percentage is its own label. No AppKit.
import CoreGraphics
import Foundation

public enum PillFileState: Equatable, Sendable {
    case waiting
    /// nil while the engine has reported no fraction above zero.
    case running(fraction: Double?)
    case done
    case failed(reason: String)
    case cancelled

    var isFinished: Bool {
        switch self {
        case .waiting, .running: false
        case .done, .failed, .cancelled: true
        }
    }
}

public struct PillFile: Equatable, Sendable, Identifiable {
    /// The file's index in its job.
    public var id: Int
    public var name: String
    public var state: PillFileState

    public init(id: Int, name: String, state: PillFileState) {
        self.id = id
        self.name = name
        self.state = state
    }
}

public enum PillPhase: Equatable, Sendable {
    case running
    case failed(ResultSummary)
    case noted(ResultSummary)
}

public struct PillJob: Equatable, Sendable, Identifiable {
    public var id: UUID
    /// "Compressing", "Converting", "Zipping".
    public var verb: String
    /// An SF Symbol name.
    public var symbol: String
    public var files: [PillFile]
    /// One output for all the files (a combine, a zip): its files can't be cancelled one by one.
    public var isCombined: Bool
    /// The wheel's centre at the drop, in screen coordinates.
    public var anchor: CGPoint
    public var startedAt: ContinuousClock.Instant
    /// True until the wheel releases the job: meanwhile its hub, not the pill, shows the outcome.
    public var isHeld: Bool
    public var phase: PillPhase

    public init(
        id: UUID, verb: String, symbol: String, files: [PillFile], isCombined: Bool, anchor: CGPoint,
        startedAt: ContinuousClock.Instant, isHeld: Bool, phase: PillPhase = .running
    ) {
        self.id = id
        self.verb = verb
        self.symbol = symbol
        self.files = files
        self.isCombined = isCombined
        self.anchor = anchor
        self.startedAt = startedAt
        self.isHeld = isHeld
        self.phase = phase
    }

    /// The average over the files, a finished file counting 1; nil while nothing has moved.
    public var fraction: Double? {
        guard !files.isEmpty else { return nil }
        let total = files.reduce(0.0) { sum, file in
            switch file.state {
            case .waiting: sum
            case .running(let fraction): sum + min(max(fraction ?? 0, 0), 1)
            case .done, .failed, .cancelled: sum + 1
            }
        }
        return total > 0 ? total / Double(files.count) : nil
    }

    public var detail: String {
        switch phase {
        case .failed(let summary), .noted(let summary):
            return summary.detail ?? ""
        case .running:
            if files.count == 1 { return ResultSummary.shortened(files[0].name, to: ResultSummary.maxTitleNameLength) }
            return "\(files.count(where: \.state.isFinished)) of \(files.count)"
        }
    }

    public var percentText: String? {
        guard phase == .running, let fraction else { return nil }
        return "\(Int((fraction * 100).rounded()))%"
    }

    public var canExpand: Bool { !isCombined && files.count > 1 }
}

public enum PillTiming {
    /// A job quicker than this never shows a pill.
    public static let showAfter: Duration = .milliseconds(500)
    public static let noteStay: Duration = .milliseconds(2500)

    /// A finished job the wheel let go of shows at once: its failure or note is news whatever its age.
    public static func isVisible(_ job: PillJob, now: ContinuousClock.Instant) -> Bool {
        guard !job.isHeld else { return false }
        return job.phase != .running || now - job.startedAt >= showAfter
    }
}

/// The pill stack's sizes and where it sits on screen. Points are AppKit screen coordinates (y up).
public enum PillLayout {
    public static let width: CGFloat = 300
    public static let collapsedHeight: CGFloat = 48
    /// One file's row in an expanded pill.
    public static let rowHeight: CGFloat = 28
    /// Between two pills of the stack.
    public static let spacing: CGFloat = 8
    /// Jobs past these show as a "2 more jobs" line.
    public static let maxVisibleJobs = 5
    /// An expanded pill's rows past these scroll.
    public static let maxVisibleRows = 6

    /// The stack's frame: the first pill centred on `anchor`, the rest below it, moved inside `visibleFrame` at its
    /// edges. A stack taller than the visible frame keeps its top, where the oldest job is, on screen.
    public static func frame(contentSize: CGSize, anchor: CGPoint, visibleFrame: CGRect) -> CGRect {
        let top = anchor.y + collapsedHeight / 2
        let placed = CGRect(origin: CGPoint(x: anchor.x - contentSize.width / 2, y: top - contentSize.height),
                            size: contentSize)
        return ScreenFit.clamp(placed, into: visibleFrame, margin: 0)
    }
}
