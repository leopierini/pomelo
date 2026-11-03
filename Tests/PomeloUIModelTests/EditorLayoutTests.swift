import CoreGraphics
import PomeloUIModel
import Testing

/// Where the editor panel opens (P27): centred on the drop point, kept 8 pt inside the screen it was dropped on.
@Suite struct EditorLayoutTests {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let size = CGSize(width: 520, height: 400)

    @Test func editorIsCentredOnTheDropPoint() {
        let f = EditorLayout.frame(contentSize: size, anchor: CGPoint(x: 500, y: 500), visibleFrame: screen)
        #expect(f == CGRect(x: 240, y: 300, width: 520, height: 400))
    }

    @Test func editorIsClampedInTheBottomRightCorner() {
        let f = EditorLayout.frame(contentSize: size, anchor: CGPoint(x: 1400, y: 60), visibleFrame: screen)
        #expect(f == CGRect(x: 912, y: 8, width: 520, height: 400))
    }

    @Test func editorIsClampedInTheTopLeftCorner() {
        let f = EditorLayout.frame(contentSize: size, anchor: CGPoint(x: 10, y: 895), visibleFrame: screen)
        #expect(f == CGRect(x: 8, y: 492, width: 520, height: 400))
    }

    @Test func editorStaysOnASecondaryScreen() {
        let f = EditorLayout.frame(contentSize: size, anchor: CGPoint(x: -100, y: 1000),
                                   visibleFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1080))
        #expect(f == CGRect(x: -528, y: 672, width: 520, height: 400))
    }

    @Test func aTallEditorPinsToTheTop() {
        let f = EditorLayout.frame(contentSize: CGSize(width: 520, height: 1200), anchor: CGPoint(x: 500, y: 500),
                                   visibleFrame: screen)
        #expect(f.origin.y == CGFloat(900 - 8 - 1200))
        #expect(f.maxY == screen.maxY - 8)
        #expect(f.size == CGSize(width: 520, height: 1200))
    }

    @Test func aWideFramePinsToTheLeft() {
        let f = ScreenFit.clamp(CGRect(x: 300, y: 100, width: 2000, height: 100), into: screen, margin: 8)
        #expect(f == CGRect(x: 8, y: 100, width: 2000, height: 100))
    }

    @Test func aFrameAlreadyInsideIsLeftAlone() {
        let frame = CGRect(x: 100, y: 100, width: 300, height: 200)
        #expect(ScreenFit.clamp(frame, into: screen, margin: 8) == frame)
    }

    @Test func widthsFollowTheKind() {
        #expect(EditorLayout.width(for: .targetSize) == 340)
        #expect(EditorLayout.width(for: .resize) == 340)
        #expect(EditorLayout.width(for: .trim) == 520)
        #expect(EditorLayout.width(for: .split) == 520)
        #expect(EditorLayout.width(for: .crop) == 520)
        #expect(EditorLayout.width(for: .rotate) == 520)
        #expect(EditorLayout.width(for: .redact) == 600)
        #expect(EditorLayout.width(for: .organizePages) == 600)
        #expect(EditorLayout.maxHeight == 560)
        #expect(EditorLayout.margin == 8)
    }
}
