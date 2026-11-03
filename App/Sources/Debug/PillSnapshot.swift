// DEBUG only: `Pomelo --snapshot-pill <out.png> <state> [light|dark]` renders the progress pill stack (P25) for a
// made-up state with ImageRenderer at scale 2, on a grey backdrop, writes a PNG and exits. Glass falls back to the
// solid background, as ImageRenderer draws neither glass nor materials. Its sample stacks also serve the evals'
// accessibility audit, hence POMELO_EVALS.
#if DEBUG || POMELO_EVALS
import AppKit
import PomeloUIModel
import SwiftUI

enum PillSnapshot {
    static let flag = "--snapshot-pill"

    enum State: String, CaseIterable {
        case running, indeterminate, several, expanded, failed, noted, stack
    }

    static var usage: String {
        "usage: Pomelo --snapshot-pill <out.png> <\(State.allCases.map(\.rawValue).joined(separator: "|"))> [light|dark]"
    }

    @MainActor
    static func runIfRequested(arguments: [String]) -> Bool {
        guard let flagIndex = arguments.firstIndex(of: flag) else { return false }
        let rest = Array(arguments[(flagIndex + 1)...])
        guard rest.count == 2 || rest.count == 3, let state = State(rawValue: rest[1]),
              rest.count == 2 || ["light", "dark"].contains(rest[2]) else {
            DebugOutput.fail(usage, 64)
        }
        let output = URL(fileURLWithPath: rest[0])
        let dark = rest.count == 3 && rest[2] == "dark"
        Task {
            do {
                try DebugOutput.render(stack(for: state).padding(16).background(Color(white: dark ? 0.25 : 0.7)),
                                          dark: dark, to: output)
            } catch {
                DebugOutput.fail("snapshot failed: \(error)")
            }
            print(output.path)
            exit(0)
        }
        return true
    }

    private static func job(
        _ verb: String, symbol: String = "rectangle.compress.vertical", files: [PillFile], phase: PillPhase = .running
    ) -> PillJob {
        PillJob(id: UUID(), verb: verb, symbol: symbol, files: files, isCombined: false, anchor: .zero,
                startedAt: .now, isHeld: false, phase: phase)
    }

    private static let video = [PillFile(id: 0, name: "long-video.mov", state: .running(fraction: 0.16))]

    /// Twelve photos in every state a row can show.
    private static let photos: [PillFile] = (0..<12).map { index in
        let state: PillFileState = switch index {
        case 0, 1, 2: .done
        case 3: .failed(reason: "The file may be damaged")
        case 4: .cancelled
        case 5: .running(fraction: 0.42)
        case 6: .running(fraction: nil)
        default: .waiting
        }
        let name = index == 2 ? "a-very-long-holiday-photo-from-the-beach.heic" : "IMG_\(4210 + index).heic"
        return PillFile(id: index, name: name, state: state)
    }

    @MainActor
    static func stack(for state: State) -> ProgressPillStack {
        switch state {
        case .running:
            return ProgressPillStack(jobs: [job("Compressing", files: video)])
        case .indeterminate:
            return ProgressPillStack(jobs: [job("Extracting audio", symbol: "waveform",
                                                files: [PillFile(id: 0, name: "interview.mp4",
                                                                 state: .running(fraction: nil))])])
        case .several:
            return ProgressPillStack(jobs: [job("Converting", symbol: "photo", files: photos)])
        case .expanded:
            let photosJob = job("Converting", symbol: "photo", files: photos)
            return ProgressPillStack(jobs: [photosJob], expanded: [photosJob.id])
        case .failed:
            let summary = ResultSummary(title: "Couldn't compress long-video.mov", detail: "The file may be damaged",
                                        isFailure: true)
            return ProgressPillStack(jobs: [job("Compressing", files: [PillFile(
                id: 0, name: "long-video.mov", state: .failed(reason: "The file may be damaged"))],
                phase: .failed(summary))])
        case .noted:
            let note = ResultSummary(title: "Saved to Downloads", detail: "The folder is read-only")
            return ProgressPillStack(jobs: [job("Reading codes", symbol: "qrcode.viewfinder",
                                                files: [PillFile(id: 0, name: "qr.png", state: .done)],
                                                phase: .noted(note))])
        case .stack:
            let failure = ResultSummary(title: "Couldn't convert bad.png", detail: "The file may be damaged",
                                        isFailure: true)
            let jobs = [
                job("Compressing", files: video),
                job("Converting", symbol: "photo", files: photos),
                job("Converting", symbol: "photo",
                    files: [PillFile(id: 0, name: "bad.png", state: .failed(reason: "The file may be damaged"))],
                    phase: .failed(failure)),
                job("Zipping", symbol: "doc.zipper",
                    files: [PillFile(id: 0, name: "Project", state: .running(fraction: nil))]),
                job("Extracting audio", symbol: "waveform",
                    files: [PillFile(id: 0, name: "interview.mp4", state: .running(fraction: 0.71))]),
            ]
            return ProgressPillStack(jobs: jobs, moreText: ProgressPillText.more(hidden: 2))
        }
    }
}
#endif
