import Foundation

/// One recognized word with its time range in seconds. The text is as the recognizer gave it: it may carry its
/// trailing punctuation or a leading space.
public struct TimedWord: Equatable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double

    public init(text: String, start: Double, end: Double) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// One subtitle: a time range in seconds and its lines. SRT and VTT writers render it.
public struct Cue: Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var lines: [String]

    public init(start: Double, end: Double, lines: [String]) {
        self.start = start
        self.end = end
        self.lines = lines
    }
}
