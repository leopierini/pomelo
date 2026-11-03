// How the DEBUG `--snapshot-*` modes and the evals hooks end: a failure on stderr with an exit code, or a PNG.
#if DEBUG || POMELO_EVALS
import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

enum DebugOutput {
    struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    static func fail(_ message: String, _ code: Int32 = 1) -> Never {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
        exit(code)
    }

    /// The arguments after `flag`; nil when it isn't one of them.
    static func arguments(after flag: String, in arguments: [String]) -> [String]? {
        arguments.firstIndex(of: flag).map { Array(arguments[($0 + 1)...]) }
    }

    /// Takes the optional `light` or `dark` at `index` of `rest`: true for dark, false for light or nothing there.
    static func takeScheme(from rest: inout [String], at index: Int) -> Bool {
        guard rest.indices.contains(index), ["light", "dark"].contains(rest[index]) else { return false }
        return rest.remove(at: index) == "dark"
    }

    /// Writes what `view` shows now as a PNG, or exits. A cached display draws the AppKit-backed controls (lists, the
    /// confirm button, the spinner) that ImageRenderer leaves out.
    @MainActor
    static func writeDisplay(of view: NSView, to output: URL) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fail("snapshot failed: no bitmap") }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]), (try? data.write(to: output)) != nil else {
            fail("snapshot failed: cannot write \(output.path)")
        }
    }

    /// Shows `host` in `window` off-screen until SwiftUI has laid it out and its AppKit views have drawn, then writes
    /// its display. For views ImageRenderer draws as a placeholder (an `NSViewRepresentable`) or leaves out.
    @MainActor
    static func writeDisplayOffScreen(_ host: NSView, in window: NSWindow, appearance: NSAppearance?,
                                      to output: URL) async {
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        window.setContentSize(host.frame.size)
        window.contentView = host
        window.appearance = appearance
        window.setFrameOrigin(NSPoint(x: -30_000, y: -32_000))
        window.orderFrontRegardless()
        if window.canBecomeKey { window.makeKey() }
        try? await Task.sleep(for: .milliseconds(500))
        writeDisplay(of: host, to: output)
    }

    /// Renders `content` with ImageRenderer at scale 2, on the solid background glass falls back to, and writes a PNG.
    @MainActor
    static func render(_ content: some View, dark: Bool, to output: URL) throws {
        // Dynamic NSColors resolve against the app's appearance, SwiftUI's against the colour scheme: set both.
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        NSApp.appearance = appearance
        let renderer = ImageRenderer(content: content
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.wheelSolidBackground, true))
        renderer.scale = 2
        var image: CGImage?
        (appearance ?? NSAppearance.currentDrawing()).performAsCurrentDrawingAppearance {
            image = renderer.cgImage
        }
        guard let image else { throw Failure(description: "ImageRenderer produced no image") }
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1,
                                                                nil) else {
            throw Failure(description: "cannot write \(output.path)")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure(description: "cannot write \(output.path)") }
    }
}
#endif
