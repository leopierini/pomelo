// Long jobs show their progress with Finder's own per-file indicator (P24): the bar under a file's icon, or the
// filling circle beside it in list view, that downloads use. Each source being worked on gets a published file
// `Progress` (the output can't carry it: it doesn't exist until it is published, and no placeholder may be made
// at the destination). It is published only once the file has run for `delay`, so quick conversions never flash an
// indicator, and Finder's cancel button on it cancels that file's work.
import Foundation

/// Publishes and unpublishes file progresses. A protocol so tests record them: a real publish shows in Finder (P16).
@MainActor
protocol FileProgressPublishing: AnyObject {
    func publish(_ progress: Progress)
    func unpublish(_ progress: Progress)
}

/// The real thing: Finder subscribes to published file progresses and draws them on the file.
@MainActor
final class FinderProgressPublisher: FileProgressPublishing {
    func publish(_ progress: Progress) { progress.publish() }
    func unpublish(_ progress: Progress) { progress.unpublish() }
}

/// One source file's indicator, from the moment its work starts until it ends. `end()` is idempotent and must be
/// called however the work ends; a cancel from Finder ends the indicator itself before calling `onCancel`.
@MainActor
final class FileProgressIndicator {
    /// How long a file's work runs before its indicator appears.
    static let standardDelay: Duration = .milliseconds(500)

    /// The progress counts per mille, not the source's bytes: Finder would describe bytes as the output's size
    /// ("1.2 GB of 2.4 GB"), and reading the size of every source (200 for a zip, maybe on a slow share) would
    /// block the main actor for nothing.
    static let unitCount: Int64 = 1000

    let progress: Progress
    private let publisher: any FileProgressPublishing
    private var pendingPublish: Task<Void, Never>?
    private var isPublished = false
    /// The whole percent the additional description shows; nil while indeterminate.
    private var shownPercent: Int?
    private(set) var hasEnded = false

    /// `progress` is a parameter so a test can count what is set on it; `sleep` so a test can run the delay on a
    /// virtual clock.
    init(
        file: URL, description: String, publisher: any FileProgressPublishing,
        delay: Duration = FileProgressIndicator.standardDelay, progress: Progress = Progress(parent: nil),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        onCancel: @escaping @MainActor () -> Void
    ) {
        self.publisher = publisher
        self.progress = progress
        // Indeterminate (a negative total) until the first fraction above zero, like `JobProgress`.
        progress.totalUnitCount = -1
        progress.kind = .file
        // There is no "converting" kind. Copying ("from source to destination") is the closest: a new file is
        // made from this one, which stays as it is. The download kinds describe the file being received, and
        // duplicating an identical copy.
        progress.fileOperationKind = .copying
        progress.fileURL = file
        progress.localizedDescription = description
        // Set, so Finder never derives one from the units (which it would read as bytes).
        progress.localizedAdditionalDescription = ""
        progress.isPausable = false
        progress.isCancellable = true
        progress.cancellationHandler = { [weak self] in
            // Finder's cancel arrives on an arbitrary thread.
            Task { @MainActor in
                guard let self, !self.hasEnded else { return }
                self.end()
                onCancel()
            }
        }
        pendingPublish = Task { [weak self] in
            try? await sleep(delay)
            guard !Task.isCancelled, let self, !self.hasEnded else { return }
            self.isPublished = true
            self.publisher.publish(self.progress)
        }
    }

    /// Shows `fraction` (0...1) of the file done; zero keeps the indicator indeterminate.
    func update(fraction: Double) {
        guard !hasEnded, fraction > 0 else { return }
        let fraction = min(fraction, 1)
        if progress.totalUnitCount != Self.unitCount { progress.totalUnitCount = Self.unitCount }
        progress.completedUnitCount = Int64((Double(Self.unitCount) * fraction).rounded())
        // Finder redraws on every change of the description: set it only when the whole percent changes (M4).
        let percent = Int((fraction * 100).rounded())
        guard percent != shownPercent else { return }
        shownPercent = percent
        progress.localizedAdditionalDescription = (Double(percent) / 100)
            .formatted(.percent.precision(.fractionLength(0)))
    }

    /// Removes the indicator (or makes sure it never appears).
    func end() {
        guard !hasEnded else { return }
        hasEnded = true
        pendingPublish?.cancel()
        pendingPublish = nil
        if isPublished {
            isPublished = false
            publisher.unpublish(progress)
        }
    }
}
