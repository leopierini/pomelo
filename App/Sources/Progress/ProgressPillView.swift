// The progress pills (P25): one per long job, stacked oldest first under the drop point. A pill reads its verb over
// the file (or "3 of 12") with the percentage as its own label (P32), a thin accent bar and a ✕; a failure turns it
// red until closed, a note shows in the accent colour. The view is a plain value: the controller replaces it on each
// change, so the panel can be sized from its fitting size at once.
import AppKit
import PomeloUIModel
import SwiftUI

/// What a pill's buttons do.
struct ProgressPillActions {
    /// The ✕: cancels a running job, closes an ended one.
    var close: (UUID) -> Void = { _ in }
    var toggleFiles: (UUID) -> Void = { _ in }
    var cancelFile: (UUID, Int) -> Void = { _, _ in }
}

/// The pills' words, VoiceOver's included.
enum ProgressPillText {
    static func title(of job: PillJob) -> String {
        switch job.phase {
        case .running: job.verb
        case .failed(let summary), .noted(let summary): summary.title
        }
    }

    static func accessibilityLabel(of job: PillJob) -> String {
        job.detail.isEmpty ? title(of: job) : "\(title(of: job)), \(job.detail)"
    }

    static func accessibilityValue(of job: PillJob) -> String? { job.percentText }

    static func closeLabel(of job: PillJob) -> String {
        job.phase == .running ? "Cancel \(job.verb)" : "Close"
    }

    static func filesLabel(isExpanded: Bool) -> String { isExpanded ? "Hide files" : "Show files" }

    static func cancelLabel(of file: PillFile) -> String { "Cancel \(file.name)" }

    /// A file's row reads its name and how it is doing; its bar and symbols are hidden from VoiceOver.
    static func accessibilityLabel(of file: PillFile) -> String {
        let state = switch file.state {
        case .waiting: "Waiting"
        case .running(let fraction): fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "Running"
        case .done: "Done"
        case .failed(let reason): reason
        case .cancelled: "Cancelled"
        }
        return "\(file.name), \(state)"
    }

    /// What VoiceOver says when a pill turns red or shows a note; progress is never announced.
    static func announcement(for job: PillJob) -> String? {
        switch job.phase {
        case .running: nil
        case .failed: job.detail.isEmpty ? title(of: job) : "\(title(of: job)). \(job.detail)"
        case .noted: title(of: job)
        }
    }

    /// The line under the stack for the jobs past `PillLayout.maxVisibleJobs`.
    static func more(hidden: Int) -> String? {
        switch hidden {
        case ..<1: nil
        case 1: "1 more job"
        default: "\(hidden) more jobs"
        }
    }
}

/// The whole stack, top-aligned in the panel: the panel may stay taller for a moment while a pill fades out.
struct ProgressPillStack: View {
    var jobs: [PillJob] = []
    var expanded: Set<UUID> = []
    var moreText: String?
    var actions = ProgressPillActions()
    /// A new stack formed while the last one was still fading out: a new identity, so the old pills leave at once.
    var generation = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let fade = 0.2

    var body: some View {
        VStack(spacing: PillLayout.spacing) {
            ForEach(jobs) { job in
                ProgressPillView(job: job, isExpanded: expanded.contains(job.id), actions: actions)
                    // Under Reduce Motion a pill still fades on its own animation, and the others jump into place.
                    .transition(reduceMotion ? .opacity.animation(.easeOut(duration: Self.fade))
                                : .opacity.combined(with: .offset(y: -6)))
            }
            if let moreText {
                Text(moreText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .wheelBackground(in: Capsule())
                    .transition(.opacity.animation(.easeOut(duration: Self.fade)))
            }
        }
        .frame(width: PillLayout.width)
        .animation(reduceMotion ? nil : .easeOut(duration: Self.fade), value: jobs.map(\.id))
        .animation(reduceMotion ? nil : .easeOut(duration: Self.fade), value: moreText)
        .animation(reduceMotion ? nil : .easeOut(duration: Self.fade), value: expanded)
        .id(generation)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// One job's pill.
struct ProgressPillView: View {
    let job: PillJob
    let isExpanded: Bool
    let actions: ProgressPillActions

    private static let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

    /// Red for a failure, the accent colour for a note, as the wheel's hub (P23, P25).
    private var style: WheelAlert.Style? {
        switch job.phase {
        case .running: nil
        case .failed: .failure
        case .noted: .note
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .frame(height: PillLayout.collapsedHeight)
            if isExpanded && job.canExpand {
                Divider()
                    .padding(.horizontal, 12)
                ProgressPillRows(job: job, actions: actions)
                    .padding(.bottom, 4)
            }
        }
        .frame(width: PillLayout.width)
        .overlay(alignment: .bottom) {
            if job.phase == .running {
                PillBar(fraction: job.fraction)
                    .frame(height: 2)
            }
        }
        .background {
            if let style {
                Self.shape.fill(WheelView.tint(of: style).opacity(0.2))
            }
        }
        .clipShape(Self.shape)
        .overlay {
            if let style {
                Self.shape.strokeBorder(WheelView.tint(of: style), lineWidth: 2)
            }
        }
        .wheelBackground(in: Self.shape)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(ProgressPillText.accessibilityLabel(of: job))
        .accessibilityValue(ProgressPillText.accessibilityValue(of: job) ?? "")
    }

    private var symbol: String {
        switch job.phase {
        case .running: job.symbol
        case .failed: "exclamationmark.triangle.fill"
        case .noted: "checkmark.circle.fill"
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(style.map { AnyShapeStyle(WheelView.tint(of: $0)) } ?? AnyShapeStyle(.secondary))
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(ProgressPillText.title(of: job))
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    if !job.detail.isEmpty {
                        Text(job.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                    if let percent = job.percentText {
                        Text(percent)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityHidden(true)
            if job.canExpand {
                PillButton(symbol: "chevron.down", label: ProgressPillText.filesLabel(isExpanded: isExpanded)) {
                    actions.toggleFiles(job.id)
                }
                .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
            PillButton(symbol: "xmark.circle.fill", label: ProgressPillText.closeLabel(of: job)) {
                actions.close(job.id)
            }
        }
        .padding(.horizontal, 12)
    }
}

/// An expanded pill's files: at most `PillLayout.maxVisibleRows` show, the rest scroll.
private struct ProgressPillRows: View {
    let job: PillJob
    let actions: ProgressPillActions
    @Environment(\.wheelSolidBackground) private var drawnForSnapshot

    var body: some View {
        let height = CGFloat(min(job.files.count, PillLayout.maxVisibleRows)) * PillLayout.rowHeight
        let rows = VStack(spacing: 0) {
            ForEach(job.files) { file in
                row(file)
                    .frame(height: PillLayout.rowHeight)
            }
        }
        if drawnForSnapshot {
            // ImageRenderer draws no NSScrollView, so the DEBUG snapshot shows the first rows clipped.
            rows.frame(height: height, alignment: .top).clipped()
        } else {
            ScrollView(.vertical) { rows }
                .scrollIndicators(job.files.count > PillLayout.maxVisibleRows ? .automatic : .never)
                .frame(height: height)
        }
    }

    private func row(_ file: PillFile) -> some View {
        HStack(spacing: 8) {
            Text(file.name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(minWidth: 72, alignment: .leading)
                .layoutPriority(1)
                .accessibilityLabel(ProgressPillText.accessibilityLabel(of: file))
            Spacer(minLength: 0)
            switch file.state {
            case .waiting:
                progress(of: file, fraction: 0)
            case .running(let fraction):
                progress(of: file, fraction: fraction)
            case .done:
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 20)
                    .accessibilityHidden(true)
            case .failed(let reason):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: .systemRed))
                    .accessibilityHidden(true)
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityHidden(true)
            case .cancelled:
                Text("Cancelled")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 12)
        .accessibilityElement(children: .contain)
    }

    /// A waiting or running file's bar and its cancel button.
    @ViewBuilder
    private func progress(of file: PillFile, fraction: Double?) -> some View {
        PillBar(fraction: fraction)
            .frame(width: 64, height: 3)
            .clipShape(Capsule())
        PillButton(symbol: "xmark.circle.fill", label: ProgressPillText.cancelLabel(of: file), size: 13) {
            actions.cancelFile(job.id, file.id)
        }
    }
}

/// A borderless symbol button with a VoiceOver label.
private struct PillButton: View {
    let symbol: String
    let label: String
    var size: CGFloat = 15
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel(label)
    }
}

/// An accent bar over a faint track: filled to `fraction`, or a 30% segment that slides while nothing is known
/// (still under Reduce Motion and in the DEBUG snapshot).
private struct PillBar: View {
    let fraction: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.wheelSolidBackground) private var drawnForSnapshot
    @State private var sliding = false

    var body: some View {
        let slides = !reduceMotion && !drawnForSnapshot
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.accentColor.opacity(0.18))
                if let fraction {
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: width * min(max(fraction, 0), 1))
                        .animation(reduceMotion ? nil : .linear(duration: 0.2), value: fraction)
                } else {
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: width * 0.3)
                        .offset(x: slides ? (sliding ? width : -width * 0.3) : width * 0.35)
                }
            }
        }
        .clipped()
        .accessibilityHidden(true)
        .onAppear {
            guard slides, fraction == nil else { return }
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { sliding = true }
        }
    }
}
