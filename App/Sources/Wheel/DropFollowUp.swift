// What the wheel does after a drop (or click-mode click) on a conversion or an engine tool, on any page (P23).
// Instead of always closing 0.35 s after the mouse-up, it waits up to `resultWait` for the job: a success closes it as
// before, a failure turns the hub red until dismissed with the wheel live again (P191), and a note shows in the accent
// colour for `noteStay`; a click elsewhere, Esc or the mouse moving well away closes either. A job still running when
// the wait ends carries on in the progress pill (P25), which shows its failure or note. The times are values so the
// tests can shorten them.
import CoreGraphics
import Foundation

struct DropFollowUp: Equatable {
    /// The least time a drag's wheel stays after the drop, so the drop is seen land (the old fixed close delay).
    var minimumStay: Duration = WheelController.closeDelay
    /// How long the wheel waits for the job's outcome.
    var resultWait: Duration = .seconds(1)
    /// How long a note stays in the hub.
    var noteStay: Duration = .milliseconds(1500)

    static let standard = DropFollowUp()

    /// How far from the wheel's centre the mouse must go to close a failure or a note: well past the 170 pt ring.
    static let dismissDistance: CGFloat = 250

    enum Decision: Equatable {
        case close
        case showFailure(WheelAlert)
        case showNote(WheelAlert)
    }

    /// What to do with a job's outcome that arrived within the wait. A success (including nothing to convert)
    /// closes; any failed file shows the summary's concise title and reason, never a raw error.
    static func decision(for outcome: JobOutcome) -> Decision {
        switch outcome {
        case .succeeded: .close
        case .failed(let summary): .showFailure(WheelAlert(title: summary.title, subtitle: summary.detail))
        case .noted(let summary): .showNote(.note(title: summary.title, subtitle: summary.detail))
        }
    }

    /// True when `point` is far enough from the wheel's `center` (screen coordinates) to close a failure or a note.
    static func movedWellAway(_ point: CGPoint, from center: CGPoint) -> Bool {
        hypot(point.x - center.x, point.y - center.y) > dismissDistance
    }
}
