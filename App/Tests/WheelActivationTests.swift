import AppKit
import Foundation
import PomeloCore
import PomeloUIModel
import Testing
@testable import Pomelo

/// A drag that rests on the wheel makes the system make the panel key and then activate Pomelo. A panel refusing the
/// key brought the Settings window in front of Finder and took Finder's focus. While the drag lasts the panel accepts
/// the key, and the activation goes back to the app the drag came from.
@MainActor
@Suite(.serialized) struct WheelActivationTests {
    private let png = URL(fileURLWithPath: "/tmp/pomelo-activation-test-a.png")
    private static let finder: pid_t = 4242

    private final class Activations {
        var handedTo: [pid_t] = []
    }

    private func makeWheel(frontmost: pid_t? = finder, _ activations: Activations) -> WheelController {
        let settings = SettingsStore(defaults: EphemeralDefaults())
        settings.settings.hapticsEnabled = false
        var desktop = WheelDesktop.offScreen
        desktop.frontmostApp = { frontmost }
        desktop.activateApp = { activations.handedTo.append($0) }
        let wheel = WheelController(settings: settings, desktop: desktop, readabilityCheck: { _, _ in .clean })
        let planner = RoutePlanner(edges: [ConversionEdge(from: "png", to: "jpg", engineID: "x", cost: 1, flags: [])],
                                   enginePriority: ["x"])
        wheel.contentBuilder = WheelContentBuilder(formats: .builtIn, available: planner, all: planner,
                                                   installHints: [:], tools: [])
        return wheel
    }

    @Test func aDragsWheelAcceptsTheKeyBeforeAnyActivationAndGivesTheActivationBack() {
        let activations = Activations()
        let wheel = makeWheel(activations)
        defer { wheel.close() }
        wheel.open(files: [png], at: NSEvent.mouseLocation, clickMode: false)
        // The system makes the panel key before Pomelo is active, so it must already accept.
        #expect(wheel.panel.canBecomeKey)

        wheel.appDidBecomeActive()
        #expect(activations.handedTo == [Self.finder])
        // A second rest during the same drag is handled the same way.
        #expect(wheel.panel.canBecomeKey)
        #expect(wheel.isOpen)
    }

    @Test func afterTheDragEndsAnActivationIsTheUsers() {
        let activations = Activations()
        let wheel = makeWheel(activations)
        defer { wheel.close() }
        wheel.open(files: [png], at: NSEvent.mouseLocation, clickMode: false)
        // A failure stays on the wheel until dismissed (P191): a click on Settings meanwhile activates Pomelo.
        wheel.dragEnded()
        #expect(!wheel.panel.canBecomeKey)

        wheel.appDidBecomeActive()
        #expect(activations.handedTo.isEmpty)
    }

    @Test func clickModeAndAClosedWheelLeaveActivationAlone() {
        let activations = Activations()
        let wheel = makeWheel(activations)
        defer { wheel.close() }
        wheel.open(files: [png], at: NSEvent.mouseLocation, clickMode: true)
        wheel.appDidBecomeActive()
        #expect(wheel.panel.canBecomeKey)

        wheel.open(files: [png], at: NSEvent.mouseLocation, clickMode: false)
        wheel.close()
        #expect(!wheel.panel.canBecomeKey)
        wheel.appDidBecomeActive()
        #expect(activations.handedTo.isEmpty)
    }

    @Test func pomeloInFrontWhenTheDragBeganGetsNothingBack() {
        let activations = Activations()
        let wheel = makeWheel(frontmost: ProcessInfo.processInfo.processIdentifier, activations)
        defer { wheel.close() }
        wheel.open(files: [png], at: NSEvent.mouseLocation, clickMode: false)
        #expect(!wheel.panel.canBecomeKey)
        wheel.appDidBecomeActive()
        #expect(activations.handedTo.isEmpty)
    }
}
