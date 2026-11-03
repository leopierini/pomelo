import Foundation
import Testing
@testable import PomeloCore

@Test func lookupByExtensionAliases() {
    let r = FormatRegistry.builtIn
    #expect(r.format(forExtension: "jpeg")?.id == "jpg")
    #expect(r.format(forExtension: "jpe")?.id == "jpg")
    #expect(r.format(forExtension: "tif")?.id == "tiff")
}
@Test func uppercaseExtension() {
    #expect(FormatRegistry.builtIn.format(for: URL(fileURLWithPath: "/x/IMG.Final.HEIC"))?.id == "heic")
}
@Test func categories() {
    let r = FormatRegistry.builtIn
    #expect(r.format(id: "mp4")?.category == .video)
    #expect(r.format(id: "pdf")?.category == .pdf)
    #expect(r.format(id: "docx")?.category == .document)
}
@Test func utTypeLookup() { #expect(FormatRegistry.builtIn.format(forUTType: "public.png")?.id == "png") }
@Test func unknownExtension() { #expect(FormatRegistry.builtIn.format(forExtension: "zzz") == nil) }
@Test func formatIDLowercases() { #expect(FormatID("PNG") == "png") }

@Test func wmaAndWMVAreKnown() {
    let registry = FormatRegistry.builtIn
    #expect(registry.format(id: "wma")?.category == .audio)
    #expect(registry.format(id: "wma")?.displayName == "Windows Media Audio")
    #expect(registry.format(id: "wma")?.utTypeIdentifier == "com.microsoft.windows-media-wma")
    #expect(registry.format(id: "wmv")?.category == .video)
    #expect(registry.format(id: "wmv")?.displayName == "Windows Media Video")
    #expect(registry.format(id: "wmv")?.utTypeIdentifier == "com.microsoft.windows-media-wmv")
    #expect(registry.format(forExtension: "WMV")?.id == "wmv")
    #expect(registry.format(forUTType: "com.microsoft.windows-media-wma")?.id == "wma")
}

@Test func archivesAreKnown() {
    let registry = FormatRegistry.builtIn
    let expected: [(FormatID, String, String)] = [
        ("zip", "ZIP archive", "public.zip-archive"), ("tar", "TAR archive", "public.tar-archive"),
        ("tgz", "Compressed TAR", "org.gnu.gnu-zip-tar-archive"), ("gz", "GZIP", "org.gnu.gnu-zip-archive"),
        ("rar", "RAR archive", "com.rarlab.rar-archive"),
    ]
    for (id, name, ut) in expected {
        let format = registry.format(id: id)
        #expect(format?.category == .archive, "\(id)")
        #expect(format?.displayName == name, "\(id)")
        #expect(format?.utTypeIdentifier == ut, "\(id)")
    }
    #expect(registry.format(forExtension: "gzip")?.id == "gz")
    // A .tar.gz is gz by its last extension; extract tells a tarball from a single gzipped file.
    #expect(registry.format(for: URL(fileURLWithPath: "/x/backup.tar.gz"))?.id == "gz")
}

@Test func csvAndJSONAreData() {
    let registry = FormatRegistry.builtIn
    #expect(registry.format(id: "csv")?.category == .data)
    #expect(registry.format(id: "csv")?.displayName == "CSV")
    #expect(registry.format(forUTType: "public.comma-separated-values-text")?.id == "csv")
    #expect(registry.format(id: "json")?.category == .data)
    #expect(registry.format(id: "json")?.displayName == "JSON")
    #expect(registry.format(forUTType: "public.json")?.id == "json")
    #expect(registry.format(for: URL(fileURLWithPath: "/x/Report.JSON"))?.id == "json")
}
