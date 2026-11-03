#if DEBUG
import CoreGraphics
import Foundation
import PomeloUIModel
import Testing
@testable import Pomelo

/// The DEBUG recorder (S34) driven with snapshots and event points, as the drag monitor and the `.leftMouseDragged`
/// monitor would feed it, writing into a temp folder. No monitor is installed.
@MainActor
@Suite struct DragTraceRecorderTests {
    private static let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private static let file = URL(fileURLWithPath: "/tmp/pomelo-recorder-test/secret-name.png")

    private func makeFolder() throws -> (parent: URL, traces: URL) {
        let parent = FileManager.default.temporaryDirectory
            .appending(path: "DragTraceRecorderTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        return (parent, parent.appending(path: "traces", directoryHint: .isDirectory))
    }

    private func recorder(_ folder: URL, now: Date = Date(timeIntervalSince1970: 1_793_450_000.123)) -> DragTraceRecorder {
        DragTraceRecorder(folder: folder, now: { now }, screenFrame: { _ in Self.screen }, watchesMouse: false)
    }

    private func snap(_ x: Double, _ y: Double, t: Double, cc: Int = 1, files: [URL] = [file],
                      down: Bool = true) -> DragSnapshot {
        DragSnapshot(buttonDown: down, changeCount: cc, fileURLs: files, modifiers: [], location: CGPoint(x: x, y: y),
                     time: t)
    }

    /// Mouse-down at `start`, files from the first tick, then `points` (absolute), then the button-up.
    @discardableResult
    private func drag(_ r: DragTraceRecorder, from start: CGPoint = CGPoint(x: 1000, y: 600), at t0: Double = 100,
                      points: [TracePoint], files: [URL] = [file], cc: Int = 1) -> URL? {
        r.sample(snap(start.x, start.y, t: t0, cc: 0, files: []), .down)
        for p in points { r.sample(snap(p.x, p.y, t: p.t, cc: cc, files: files), .tick) }
        let last = points.last ?? TracePoint(t: t0, x: start.x, y: start.y)
        return r.sample(snap(last.x, last.y, t: last.t + 1.0 / 60, cc: cc, files: files, down: false), .up)
    }

    private func decode(_ url: URL) throws -> DragTrace {
        try JSONDecoder().decode(DragTrace.self, from: Data(contentsOf: url))
    }

    @Test func traceIsRelativeToMouseDown() throws {
        let (parent, traces) = try makeFolder()
        defer { try? FileManager.default.removeItem(at: parent) }
        let r = recorder(traces)
        r.sample(snap(1000, 600, t: 100, cc: 0, files: []), .down)
        r.sample(snap(1000, 600, t: 100.2), .tick)
        r.sample(snap(1010, 590, t: 100.5), .tick)
        r.dragged(to: CGPoint(x: 1020, y: 600), at: 100.6)
        let url = try #require(r.sample(snap(1030, 600, t: 100.7, down: false), .up))
        let trace = try decode(url)
        #expect(trace.poll == [TracePoint(t: 0, x: 0, y: 0), TracePoint(t: 0.2, x: 0, y: 0),
                               TracePoint(t: 0.5, x: 10, y: -10)])
        #expect(trace.events == [TracePoint(t: 0.6, x: 20, y: 0)])
        #expect(trace.filesSeenAt == 0.2)
        #expect(trace.fileCount == 1)
        #expect(trace.screen == CGRect(x: -1000, y: -600, width: 1920, height: 1080))
        #expect(trace.label == .ordinary)
        #expect(r.counts[.ordinary] == 1)
    }

    @Test func dragWithoutFilesWritesNothing() throws {
        let (parent, traces) = try makeFolder()
        defer { try? FileManager.default.removeItem(at: parent) }
        let r = recorder(traces)
        let points = (1...30).map { TracePoint(t: 100 + Double($0) / 60, x: 1000 + Double($0), y: 600) }
        // A text drag moves the pasteboard without files; a click leaves it alone.
        #expect(drag(r, points: points, files: []) == nil)
        #expect(drag(r, points: points, cc: 0) == nil)
        let written = (try? FileManager.default.contentsOfDirectory(atPath: traces.path)) ?? []
        #expect(written.isEmpty)
        #expect(r.counts.values.reduce(0, +) == 0)
    }

    /// A 50 pt, 5 Hz shake after the arming delay: under Careful's 60 pt minimum leg, over Normal's and Easy's.
    @Test func wouldFireIsRecordedPerPreset() throws {
        let (parent, traces) = try makeFolder()
        defer { try? FileManager.default.removeItem(at: parent) }
        let r = recorder(traces)
        r.label = .shakeMouse
        let still = (1...24).map { TracePoint(t: 100 + Double($0) / 60, x: 1000, y: 600) }
        let start = still.last!.t
        let shake = (1...60).map { k -> TracePoint in
            let t = Double(k) / 60
            return TracePoint(t: start + t, x: 1000 + 25 * sin(2 * .pi * 5 * t), y: 600)
        }
        let url = try #require(drag(r, points: still + shake))
        let trace = try decode(url)
        #expect(trace.label == .shakeMouse)
        #expect(trace.wouldFire == ["careful": false, "normal": true, "easy": true])
        #expect(url.lastPathComponent.hasSuffix("-shakeMouse.json"))
        #expect(r.counts[.shakeMouse] == 1)
        #expect(r.shadowFires[.normal] == DragTraceRecorder.Fires(ordinary: 0, shakes: 1))
        #expect(r.shadowFires[.careful, default: .init()] == DragTraceRecorder.Fires(ordinary: 0, shakes: 0))
    }

    @Test func traceHoldsNoPathOrName() throws {
        let (parent, traces) = try makeFolder()
        defer { try? FileManager.default.removeItem(at: parent) }
        let points = (1...30).map { TracePoint(t: 100 + Double($0) / 60, x: 1000 + Double($0), y: 600) }
        let url = try #require(drag(recorder(traces), points: points))
        let json = try String(contentsOf: url, encoding: .utf8)
        for secret in ["secret-name", "/tmp", "file:", "pomelo-recorder-test"] {
            #expect(!json.contains(secret))
            #expect(!url.lastPathComponent.contains(secret))
        }
    }

    @Test func writesOnlyInsideTheFolder() throws {
        let (parent, traces) = try makeFolder()
        defer { try? FileManager.default.removeItem(at: parent) }
        let points = (1...30).map { TracePoint(t: 100 + Double($0) / 60, x: 1000 + Double($0), y: 600) }
        let first = try #require(drag(recorder(traces, now: Date(timeIntervalSince1970: 1_793_450_000.123)), points: points))
        let second = try #require(drag(recorder(traces, now: Date(timeIntervalSince1970: 1_793_450_001.456)), points: points))
        #expect(first.deletingLastPathComponent().standardizedFileURL == traces.standardizedFileURL)
        #expect(second.deletingLastPathComponent().standardizedFileURL == traces.standardizedFileURL)
        let everything = try FileManager.default.subpathsOfDirectory(atPath: parent.path).sorted()
        #expect(everything == ["traces", "traces/\(first.lastPathComponent)", "traces/\(second.lastPathComponent)"])
        let pattern = /^\d{8}-\d{6}-\d{3}-ordinary\.json$/
        #expect(first.lastPathComponent.wholeMatch(of: pattern) != nil)
        #expect(second.lastPathComponent.wholeMatch(of: pattern) != nil)
        #expect(first != second)
    }

    /// The recorder only ever writes, but writing into a folder macOS guards would still ask a permission.
    @Test func refusesAProtectedFolder() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for folder in ["\(home)/Desktop/traces", "\(home)/Documents", "\(home)/Downloads/x"] {
            #expect(throws: DebugOutput.Failure.self) {
                try DragTraceRecorder.folder(in: ["Pomelo", DragTraceRecorder.flag, folder])
            }
        }
        #expect(throws: DebugOutput.Failure.self) { try DragTraceRecorder.folder(in: ["Pomelo", DragTraceRecorder.flag]) }
        #expect(try DragTraceRecorder.folder(in: ["Pomelo"]) == nil)
        let cache = "\(home)/Library/Caches/Pomelo-build/drag-traces"
        #expect(try DragTraceRecorder.folder(in: ["Pomelo", DragTraceRecorder.flag, cache])?.path == cache)
    }

    /// R14: the file system ignores case, so a lowercase spelling of a protected folder is the same folder.
    @Test func refusesAProtectedFolderInAnyCase() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for folder in ["\(home)/desktop/x", "\(home)/DOCUMENTS/traces/new"] {
            #expect(throws: DebugOutput.Failure.self) {
                try DragTraceRecorder.folder(in: ["Pomelo", DragTraceRecorder.flag, folder])
            }
        }
    }

    /// R14: a link into a protected folder, followed by folders that don't exist yet, is refused without ever
    /// looking through the link (creating the link never touches its target).
    @Test func refusesALinkIntoAProtectedFolder() throws {
        let (parent, _) = try makeFolder()
        defer { try? FileManager.default.removeItem(at: parent) }
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Desktop").path
        let link = parent.appending(path: "deskLink")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: desktop)
        #expect(throws: DebugOutput.Failure.self) {
            try DragTraceRecorder.folder(in: ["Pomelo", DragTraceRecorder.flag, link.path + "/new/deeper"])
        }
        // A temp folder that doesn't exist yet is fine, and comes back resolved.
        let fresh = try #require(try DragTraceRecorder.folder(in: ["Pomelo", DragTraceRecorder.flag,
                                                                   parent.path + "/traces/new"]))
        #expect(fresh.path.hasSuffix("/traces/new"))
        #expect(fresh.path.hasPrefix("/private/"))
    }

    /// R14: only a folder under ~/Library/Caches or a temporary folder.
    @Test func refusesAFolderOutsideCachesAndTemp() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for folder in ["\(home)/Pictures/traces", "\(home)/Library", "/Applications/traces", "/"] {
            #expect(throws: DebugOutput.Failure.self) {
                try DragTraceRecorder.folder(in: ["Pomelo", DragTraceRecorder.flag, folder])
            }
        }
    }
}
#endif
