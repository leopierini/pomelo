import Foundation
import Testing
@testable import PomeloCore

private func e(
    _ f: FormatID, _ t: FormatID, _ eng: EngineID = "a", _ c: Int = 10, _ fl: EdgeFlags = [], op: String? = nil
) -> ConversionEdge {
    ConversionEdge(from: f, to: t, engineID: eng, cost: c, flags: fl, operation: op)
}

@Test func directBeatsChain() throws {
    let p = RoutePlanner(edges: [e("png", "jpg"), e("png", "tiff"), e("tiff", "jpg")], enginePriority: ["a"])
    let r = try #require(p.route(from: "png", to: "jpg"))
    #expect(r.edges.count == 1); #expect(r.totalCost == 15)
}
@Test func findsTwoHopChain() throws {
    let p = RoutePlanner(edges: [e("heic", "png", "imageio"), e("png", "webp", "cwebp", 30)], enginePriority: ["imageio", "cwebp"])
    let r = try #require(p.route(from: "heic", to: "webp"))
    #expect(r.edges.map(\.engineID) == ["imageio", "cwebp"]); #expect(r.totalCost == 50)
}
@Test func respectsMaxHops() {
    let p = RoutePlanner(edges: [e("a", "b"), e("b", "c"), e("c", "d"), e("d", "e")], enginePriority: ["a"])
    #expect(p.route(from: "a", to: "d") != nil); #expect(p.route(from: "a", to: "e") == nil)
}
@Test func directOnlyNeverIntermediate() {
    let p = RoutePlanner(edges: [e("pdf", "pptx", "a", 10, .directOnly), e("pptx", "odp")], enginePriority: ["a"])
    #expect(p.route(from: "pdf", to: "pptx") != nil); #expect(p.route(from: "pdf", to: "odp") == nil)
}
@Test func layoutRiskPenaltyPrefersFaithfulEngine() {
    let p = RoutePlanner(edges: [e("docx", "pdf", "attributedtext", 10, .layoutRisk), e("docx", "pdf", "libreoffice", 60)],
                         enginePriority: ["attributedtext", "libreoffice"])
    #expect(p.route(from: "docx", to: "pdf")?.edges.first?.engineID == "libreoffice")
}
@Test func priorityBreaksTies() {
    let p = RoutePlanner(edges: [e("png", "jpg", "a"), e("png", "jpg", "b")], enginePriority: ["b", "a"])
    #expect(p.route(from: "png", to: "jpg")?.edges.first?.engineID == "b")
}
@Test func sameFormatOnlyViaSelfEdge() {
    let p = RoutePlanner(edges: [e("png", "png"), e("png", "jpg"), e("jpg", "png")], enginePriority: ["a"])
    #expect(p.route(from: "png", to: "png")?.edges.count == 1)
    #expect(p.reachableTargets(from: "png").keys.contains("png") == false)
}
@Test func noRevisitedFormats() {
    let p = RoutePlanner(edges: [e("a", "b"), e("b", "a"), e("b", "c")], enginePriority: ["a"])
    #expect(p.route(from: "a", to: "c")?.edges.count == 2)
}
@Test func fewerLossyEdgesBreakTiesBeforePriority() {
    // Both routes score 30 in 2 hops; the lossy one uses the higher-priority engine and is listed first.
    let p = RoutePlanner(edges: [e("a", "b", "first", 10, .lossy), e("b", "d", "first"), e("a", "c", "second"), e("c", "d", "second")],
                         enginePriority: ["first", "second"])
    #expect(p.route(from: "a", to: "d")?.edges.map(\.to) == ["c", "d"])
}
@Test func formatSequenceBreaksRemainingTiesWhateverTheEdgeOrder() {
    let edges = [e("a", "b"), e("b", "d"), e("a", "c"), e("c", "d")]
    for ordering in [edges, Array(edges.reversed()), [edges[2], edges[0], edges[3], edges[1]]] {
        let p = RoutePlanner(edges: ordering, enginePriority: ["a"])
        #expect(p.route(from: "a", to: "d")?.edges.map(\.to) == ["b", "d"])
    }
}

@Test func operationEdgesNeverJoinPlainRoutes() {
    let p = RoutePlanner(edges: [e("mp4", "mp4", op: "remove-audio"), e("mp4", "mov")], enginePriority: [])
    #expect(p.route(from: "mp4", to: "mp4") == nil)
    #expect(p.reachableTargets(from: "mp4").keys.map(\.rawValue).sorted() == ["mov"])
    #expect(p.route(from: "mp4", operation: "remove-audio", to: nil)?.edges.count == 1)
}
@Test func operationEdgesNeverBecomeChainSteps() {
    let p = RoutePlanner(edges: [e("mp4", "png", op: "snapshot"), e("png", "jpg")], enginePriority: [])
    #expect(p.route(from: "mp4", to: "jpg") == nil)
    #expect(p.route(from: "mp4", operation: "snapshot", to: "jpg") == nil)
}
@Test func operationRouteHonoursTheTarget() {
    let p = RoutePlanner(edges: [e("mp4", "png", op: "snapshot")], enginePriority: [])
    #expect(p.route(from: "mp4", operation: "snapshot", to: "png")?.edges.first?.to == "png")
    #expect(p.route(from: "mp4", operation: "snapshot", to: "jpg") == nil)
    #expect(p.route(from: "mp4", operation: "snapshot", to: nil) == nil)
    #expect(p.route(from: "mp4", operation: "other", to: "png") == nil)
}
@Test func operationRoutePrefersTheCheaperEngine() {
    let p = RoutePlanner(
        edges: [e("mp4", "mp4", "ffmpeg", 30, op: "speed"), e("mp4", "mp4", "avfoundation", 10, op: "speed")],
        enginePriority: ["ffmpeg", "avfoundation"])
    #expect(p.route(from: "mp4", operation: "speed", to: nil)?.edges.first?.engineID == "avfoundation")
}
@Test func operationRouteBreaksTiesByPriorityThenFormat() {
    let byPriority = RoutePlanner(
        edges: [e("mp4", "mp4", "a", op: "x"), e("mp4", "mp4", "b", op: "x")], enginePriority: ["b", "a"])
    #expect(byPriority.route(from: "mp4", operation: "x", to: nil)?.edges.first?.engineID == "b")
}

/// The one rule Tools, watch folders and jobs share: a tool runs its operation's edge, anything else converts to its
/// target, or to the source's own format when it has none.
@Test func aToolOrARequestRunsItsOperationElseConverts() throws {
    let p = RoutePlanner(
        edges: [e("png", "jpg"), e("png", "png", "b", op: "compress"), e("png", "png", "c")], enginePriority: ["a", "b", "c"])
    #expect(p.route(from: "png", operation: "compress", target: nil)?.edges.map(\.engineID) == ["b"])
    #expect(p.route(from: "png", operation: "compress", target: "jpg") == nil)
    #expect(p.route(from: "png", operation: nil, target: "jpg") == p.route(from: "png", to: "jpg"))
    #expect(p.route(from: "png", operation: nil, target: nil)?.edges.map(\.engineID) == ["c"])
}
