import CoreGraphics
import Foundation
import Testing
@testable import PomeloCore

private let sortedEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
}()

private func roundTrip(_ edit: EditSpec) throws -> EditSpec {
    try JSONDecoder().decode(EditSpec.self, from: sortedEncoder.encode(edit))
}

@Suite struct EditSpecTests {
    @Test func trimEncodesFlatWithItsKind() throws {
        let json = try sortedEncoder.encode(EditSpec.trim(TimeRange(start: 2, end: 10)))
        #expect(String(decoding: json, as: UTF8.self) == #"{"end":10,"kind":"trim","start":2}"#)
    }

    @Test func everyShapeEncodesAsDocumented() throws {
        func text(_ edit: EditSpec) throws -> String {
            String(decoding: try sortedEncoder.encode(edit), as: UTF8.self)
        }
        #expect(try text(.split([2, 4])) == #"{"kind":"split","points":[2,4]}"#)
        #expect(try text(.crop(UnitRect(x: 0, y: 0, width: 0.5, height: 0.5)))
            == #"{"height":0.5,"kind":"crop","width":0.5,"x":0,"y":0}"#)
        #expect(try text(.redact(RedactionSpec(boxes: [UnitRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)], style: .fill)))
            == #"{"boxes":[{"height":0.4,"width":0.3,"x":0.1,"y":0.2}],"kind":"redact","style":"fill"}"#)
        #expect(try text(.organize([PageEdit(page: 2, rotation: 0), PageEdit(page: 0, rotation: 90)]))
            == #"{"kind":"organize","pages":[{"page":2,"rotation":0},{"page":0,"rotation":90}]}"#)
        #expect(try text(.resize(.scale(percent: 50))) == #"{"kind":"resize","mode":"scale","percent":50}"#)
        #expect(try text(.resize(.width(200))) == #"{"kind":"resize","mode":"width","width":200}"#)
        #expect(try text(.resize(.height(200))) == #"{"height":200,"kind":"resize","mode":"height"}"#)
        #expect(try text(.resize(.exact(width: 1080, height: 720)))
            == #"{"height":720,"kind":"resize","mode":"exact","width":1080}"#)
        #expect(try text(.rotate(RotateSpec(quarterTurns: 1, flipHorizontal: true)))
            == #"{"flipHorizontal":true,"kind":"rotate","quarterTurns":1}"#)
    }

    @Test func resizeAndRotateRoundTrip() throws {
        let edits: [EditSpec] = [
            .resize(.scale(percent: 12.5)), .resize(.width(1000)), .resize(.height(720)),
            .resize(.exact(width: 600, height: 600)),
            .rotate(.identity), .rotate(RotateSpec(quarterTurns: 3, flipHorizontal: true)),
        ]
        for edit in edits { #expect(try roundTrip(edit) == edit) }
        for spec in [ResizeSpec.scale(percent: 200), .exact(width: 3, height: 4)] {
            #expect(try JSONDecoder().decode(ResizeSpec.self, from: JSONEncoder().encode(spec)) == spec)
        }
    }

    @Test func aBadResizeOrRotateFailsToDecode() throws {
        for json in [
            #"{"kind":"resize","mode":"stretch","width":10}"#, #"{"kind":"resize","width":10}"#,
            #"{"kind":"resize","mode":"width"}"#, #"{"kind":"resize","mode":"exact","width":10}"#,
            #"{"kind":"rotate"}"#,
        ] {
            #expect(throws: DecodingError.self, "\(json)") {
                try JSONDecoder().decode(EditSpec.self, from: Data(json.utf8))
            }
        }
        let turned = try JSONDecoder().decode(EditSpec.self, from: Data(#"{"kind":"rotate","quarterTurns":5}"#.utf8))
        #expect(turned == .rotate(RotateSpec(quarterTurns: 1, flipHorizontal: false)))
    }

    @Test func everyEditRoundTrips() throws {
        let edits: [EditSpec] = [
            .trim(TimeRange(start: 0.5, end: 7.25)),
            .split([1.5, 3]),
            .crop(UnitRect(x: 0.1, y: 0.2, width: 0.5, height: 0.25)),
            .redact(RedactionSpec(
                boxes: [UnitRect(x: 0, y: 0, width: 0.5, height: 0.5), UnitRect(x: 0.5, y: 0.5, width: 0.25, height: 0.25)],
                style: .pixelate
            )),
            .organize([PageEdit(page: 1, rotation: 270), PageEdit(page: 0, rotation: 0)]),
        ]
        for edit in edits { #expect(try roundTrip(edit) == edit) }
    }

    @Test func anUnknownKindFailsToDecode() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(EditSpec.self, from: Data(#"{"kind":"blur","radius":3}"#.utf8))
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(EditSpec.self, from: Data(#"{"start":1,"end":2}"#.utf8))
        }
    }

    @Test func pixelsRoundOutwardsAndClamp() {
        #expect(UnitRect(x: 0.2502, y: 0, width: 0.4996, height: 1).pixels(width: 200, height: 100)
                == CGRect(x: 50, y: 0, width: 100, height: 100))
        #expect(UnitRect(x: 0.9, y: 0.9, width: 0.5, height: 0.5).pixels(width: 100, height: 100)
                == CGRect(x: 90, y: 90, width: 10, height: 10))
    }

    @Test func floatingPointNoiseDoesNotGrowARectByAPixel() {
        #expect(UnitRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2).pixels(width: 100, height: 100)
                == CGRect(x: 10, y: 10, width: 20, height: 20))
    }

    @Test func clampedStaysInsideTheUnitSquare() {
        let clamped = UnitRect(x: -0.2, y: 0.8, width: 1.5, height: 0.5).clamped()
        #expect(clamped.x == 0 && clamped.width == 1)
        #expect(clamped.y + clamped.height <= 1)
        #expect(UnitRect(x: 0.5, y: 0.5, width: -1, height: 0.1).clamped().width == 0)
    }

    @Test func trimPlaceholdersExpand() {
        let o = PresetOptions(edit: .trim(TimeRange(start: 2.5, end: 10)))
        #expect(o.templateValue(for: "trimStart") == "2.500")
        #expect(o.templateValue(for: "trimEnd") == "10.000")
        #expect(o.templateValue(for: "trimDuration") == "7.500")
        #expect(PresetOptions().templateValue(for: "trimStart") == nil)
        #expect(PresetOptions(edit: .crop(UnitRect(x: 0, y: 0, width: 1, height: 1))).templateValue(for: "trimEnd") == nil)
    }

    @Test func targetBytesIsATemplateValue() {
        #expect(PresetOptions(targetBytes: 5_000_000).templateValue(for: "targetBytes") == "5000000")
        #expect(PresetOptions().templateValue(for: "targetBytes") == nil)
    }

    @Test func olderOptionsAndPresetsDecode() throws {
        let options = try JSONDecoder().decode(
            PresetOptions.self, from: Data(#"{"quality":0.5,"stripMetadata":false}"#.utf8))
        #expect(options.edit == nil)
        #expect(options.targetBytes == nil)
        let preset = try JSONDecoder().decode(
            Preset.self, from: Data(#"{"id":"x","name":"X","target":"png","options":{"quality":0.5}}"#.utf8))
        #expect(preset.needsInput == false)
    }

    @Test func optionsWithAnEditRoundTrip() throws {
        let options = PresetOptions(
            quality: 0.7, edit: .redact(RedactionSpec(boxes: [UnitRect(x: 0, y: 0, width: 0.5, height: 0.5)], style: .fill)),
            targetBytes: 1_000_000)
        #expect(try JSONDecoder().decode(PresetOptions.self, from: JSONEncoder().encode(options)) == options)
    }

    @Test func editorPresetsNeedInput() throws {
        let editors: Set<String> = [
            "trim", "crop", "split-video", "compress-to-size", "redact", "organize-pages", "resize", "rotate",
        ]
        for id in editors {
            let preset = try #require(Preset.builtIns.first { $0.id == id }, "\(id)")
            #expect(preset.needsInput, "\(id)")
        }
        for preset in Preset.builtIns where !editors.contains(preset.id) {
            #expect(!preset.needsInput, "\(preset.id)")
        }
    }

    @Test func editorPresetsMatchTheTable() throws {
        func preset(_ id: String) throws -> Preset { try #require(Preset.builtIns.first { $0.id == id }) }
        let trim = try preset("trim")
        #expect(trim.name == "Trim\u{2026}" && trim.operation == "trim" && trim.target == nil)
        #expect(trim.categories == [.video, .audio] && trim.nameSuffix == "trimmed")
        let crop = try preset("crop")
        #expect(crop.name == "Crop\u{2026}" && crop.operation == "crop" && crop.options.quality == 0.92)
        #expect(crop.categories == [.image, .video] && crop.nameSuffix == "cropped")
        let split = try preset("split-video")
        #expect(split.name == "Split\u{2026}" && split.operation == "split" && split.categories == [.video])
        #expect(split.nameSuffix == "parts")
        let size = try preset("compress-to-size")
        #expect(size.name == "Compress to size\u{2026}" && size.operation == "target-size")
        #expect(size.categories == [.image, .pdf, .video] && size.nameSuffix == "smaller")
        let redact = try preset("redact")
        #expect(redact.name == "Redact\u{2026}" && redact.operation == "redact" && redact.options.quality == 0.92)
        #expect(redact.categories == [.image] && redact.nameSuffix == "redacted")
        let resize = try preset("resize")
        #expect(resize.name == "Resize\u{2026}" && resize.operation == "resize" && resize.target == nil)
        #expect(resize.options.quality == 0.92 && resize.categories == [.image, .video])
        #expect(resize.outputNaming == .fromOutput && resize.needsInput)
        let rotate = try preset("rotate")
        #expect(rotate.name == "Rotate\u{2026}" && rotate.operation == "rotate" && rotate.target == nil)
        #expect(rotate.options.quality == 0.92 && rotate.categories == [.image, .video])
        #expect(rotate.nameSuffix == "rotated" && rotate.outputNaming == .fromSource)
        let pages = try preset("organize-pages")
        #expect(pages.name == "Organize pages\u{2026}" && pages.operation == "organize" && pages.target == "pdf")
        #expect(pages.categories == [.pdf] && pages.nameSuffix == "edited")
    }
}
