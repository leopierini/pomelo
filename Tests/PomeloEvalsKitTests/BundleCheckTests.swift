import Foundation
import Testing
import PomeloTestSupport
@testable import PomeloEvalsKit

/// A fake `Pomelo.app` with an appex, built from a tiny C program and signed ad hoc; never a real installed app.
private struct FakeBundle {
    var universalApp = true
    var universalAppex = true
    var appEntitlements = #"<key>com.apple.security.automation.apple-events</key><true/>"#
    var appexEntitlements = #"<key>com.apple.security.app-sandbox</key><true/>"#
    var appexPresent = true
    var appIntentsPresent = true
    var sign = true
    var appHardenedRuntime = true
    var appexHardenedRuntime = true
    var tamperAfterSigning = false
    /// Linker flags for the app's executable, such as `["-weak_framework", "Translation"]`.
    var appLinks: [String] = []

    static func plist(_ body: String) -> String {
        #"<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>\#(body)</dict></plist>"#
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    func compile(into url: URL, universal: Bool, links: [String] = [], in work: URL) throws {
        let source = work.appending(path: "main.c")
        try "int main(void) { return 0; }\n".write(to: source, atomically: true, encoding: .utf8)
        let archs = universal ? ["-arch", "arm64", "-arch", "x86_64"] : ["-arch", "arm64"]
        let status = try Self.run("/usr/bin/clang", archs + ["-o", url.path, source.path] + links)
        #expect(status == 0, "clang could not build the fixture binary")
    }

    func build(in work: URL) throws -> (app: URL, entitlements: URL) {
        let fm = FileManager.default
        let app = work.appending(path: "Fake.app")
        let macOS = app.appending(path: "Contents/MacOS")
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        try compile(into: macOS.appending(path: "Fake"), universal: universalApp, links: appLinks, in: work)
        try Self.plist("<key>CFBundleExecutable</key><string>Fake</string><key>CFBundleIdentifier</key><string>x.Fake</string>")
            .write(to: app.appending(path: "Contents/Info.plist"), atomically: true, encoding: .utf8)
        let resources = app.appending(path: "Contents/Resources")
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)
        if appIntentsPresent {
            try fm.createDirectory(at: resources.appending(path: "Metadata.appintents"), withIntermediateDirectories: true)
            try "{}".write(to: resources.appending(path: "Metadata.appintents/extract.actionsdata"), atomically: true, encoding: .utf8)
        }

        let entitlements = work.appending(path: "entitlements", directoryHint: .isDirectory)
        try fm.createDirectory(at: entitlements, withIntermediateDirectories: true)
        let appEntitlementsFile = entitlements.appending(path: "Pomelo.entitlements")
        let appexEntitlementsFile = entitlements.appending(path: "PomeloQuickAction.entitlements")
        try Self.plist(#"<key>com.apple.security.automation.apple-events</key><true/>"#)
            .write(to: appEntitlementsFile, atomically: true, encoding: .utf8)
        try Self.plist(#"<key>com.apple.security.app-sandbox</key><true/>"#)
            .write(to: appexEntitlementsFile, atomically: true, encoding: .utf8)

        let signingFiles = work.appending(path: "signing", directoryHint: .isDirectory)
        try fm.createDirectory(at: signingFiles, withIntermediateDirectories: true)
        if appexPresent {
            let appex = app.appending(path: "Contents/PlugIns/PomeloQuickAction.appex")
            let appexMacOS = appex.appending(path: "Contents/MacOS")
            try fm.createDirectory(at: appexMacOS, withIntermediateDirectories: true)
            try compile(into: appexMacOS.appending(path: "PomeloQuickAction"), universal: universalAppex, in: work)
            try Self.plist("<key>CFBundleExecutable</key><string>PomeloQuickAction</string><key>CFBundleIdentifier</key><string>x.Fake.QuickAction</string>")
                .write(to: appex.appending(path: "Contents/Info.plist"), atomically: true, encoding: .utf8)
            if sign {
                let file = signingFiles.appending(path: "appex.entitlements")
                try Self.plist(appexEntitlements).write(to: file, atomically: true, encoding: .utf8)
                try Self.run("/usr/bin/codesign", ["--force", "-s", "-", "--entitlements", file.path]
                    + (appexHardenedRuntime ? ["-o", "runtime"] : []) + [appex.path])
            }
        }
        if sign {
            let file = signingFiles.appending(path: "app.entitlements")
            try Self.plist(appEntitlements).write(to: file, atomically: true, encoding: .utf8)
            try Self.run("/usr/bin/codesign", ["--force", "-s", "-", "--entitlements", file.path]
                + (appHardenedRuntime ? ["-o", "runtime"] : []) + [app.path])
        }
        if tamperAfterSigning {
            try Data("tampered".utf8).write(to: app.appending(path: "Contents/Resources/Tamper.txt"))
            let handle = try FileHandle(forWritingTo: macOS.appending(path: "Fake"))
            try handle.seekToEnd()
            try handle.write(contentsOf: Data([0]))
            try handle.close()
        }
        return (app, entitlements)
    }
}

private func checks(
    _ fake: FakeBundle, configuration: BundleCheck.Configuration = .release
) throws -> [String: EvalResults.Check] {
    let work = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: work) }
    let (app, entitlements) = try fake.build(in: work)
    let list = BundleCheck.run(app: app, expectedEntitlements: entitlements, configuration: configuration)
    return Dictionary(uniqueKeysWithValues: list.map { ($0.name, $0) })
}

@Suite struct BundleCheckTests {
    @Test func aCompleteBundlePassesEveryCheck() throws {
        let result = try checks(FakeBundle())
        #expect(Set(result.keys) == [
            "bundle-structure.archs", "bundle-structure.signature", "bundle-structure.entitlements",
            "bundle-structure.appex", "bundle-structure.appintents", "bundle-structure.hardened-runtime",
            "bundle-structure.weak-links", "bundle-structure.sdk",
        ])
        for check in result.values { #expect(check.ok, "\(check.name): \(check.detail)") }
        #expect(result["bundle-structure.weak-links"]?.detail == "FoundationModels and Translation are not linked yet")
    }

    /// The app runs on macOS 14: a framework that only macOS 26 has must load weakly, or the app won't launch there.
    @Test func theMacOS26FrameworksMustLoadWeakly() throws {
        var weak = FakeBundle()
        weak.appLinks = ["-weak_framework", "FoundationModels", "-weak_framework", "Translation"]
        let weakResult = try checks(weak)["bundle-structure.weak-links"]
        #expect(weakResult?.ok == true)
        #expect(weakResult?.detail == "FoundationModels and Translation load weakly")

        var strong = FakeBundle()
        strong.appLinks = ["-weak_framework", "FoundationModels", "-framework", "Translation"]
        let strongResult = try checks(strong)["bundle-structure.weak-links"]
        #expect(strongResult?.ok == false)
        #expect(strongResult?.detail == "Translation is linked strongly")
    }

    /// Translation behaves by the SDK a binary was linked against, not the OS it runs on (P163): below 26.4 every
    /// installed language reads as merely supported.
    @Test func theAppAndTheCLIMustBeLinkedAgainstSDK264OrLater() throws {
        #expect(try checks(FakeBundle())["bundle-structure.sdk"]?.ok == true)

        var old = FakeBundle()
        old.appLinks = ["-Wl,-platform_version,macos,14.0,26.0"]
        let oldResult = try checks(old)["bundle-structure.sdk"]
        #expect(oldResult?.ok == false)
        #expect(oldResult?.detail == "the app is linked against SDK 26.0, Translation needs 26.4 or later")

        let work = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: work) }
        let (app, entitlements) = try FakeBundle().build(in: work)
        let cli = work.appending(path: "pomelo")
        let source = work.appending(path: "cli.c")
        try "int main(void) { return 0; }\n".write(to: source, atomically: true, encoding: .utf8)
        func build(sdk: String) throws {
            try FakeBundle.run("/usr/bin/clang", ["-arch", "arm64", "-o", cli.path, source.path,
                                                    "-Wl,-platform_version,macos,14.0,\(sdk)"])
        }
        func sdkCheck() -> EvalResults.Check? {
            BundleCheck.run(app: app, expectedEntitlements: entitlements, cli: cli).first { $0.name == "bundle-structure.sdk" }
        }
        try build(sdk: "26.4")
        #expect(sdkCheck()?.ok == true)
        try build(sdk: "14.0")
        #expect(sdkCheck()?.detail == "the CLI is linked against SDK 14.0, Translation needs 26.4 or later")
    }

    @Test func sdkVersionsAreReadFromEveryBuildVersionCommand() {
        let output = """
            Load command 8
                      cmd LC_BUILD_VERSION
                  cmdsize 32
                 platform 1
                    minos 14.0
                      sdk 26.4
                   ntools 1
            Load command 9
                      cmd LC_VERSION_MIN_MACOSX
                  cmdsize 16
                  version 10.9
                      sdk 10.15
            Load command 10
                      cmd LC_BUILD_VERSION
                 platform 1
                    minos 14.0
                      sdk 27.0.1
            Load command 11
                      cmd LC_SOURCE_VERSION
                  version 0.0
            """
        #expect(BundleCheck.sdkVersions(inLoadCommands: output) == [[26, 4], [10, 15], [27, 0, 1]])
        #expect([26, 3, 9].lexicographicallyPrecedes(BundleCheck.minimumSDK))
        #expect(![26, 4].lexicographicallyPrecedes(BundleCheck.minimumSDK))
        #expect(![27, 0, 1].lexicographicallyPrecedes(BundleCheck.minimumSDK))
    }

    @Test func frameworkLoadsAreReadFromEveryLoadCommand() {
        let output = """
            Load command 12
                      cmd LC_LOAD_DYLIB
                  cmdsize 88
                     name /System/Library/Frameworks/AppKit.framework/Versions/C/AppKit (offset 24)
            Load command 13
                      cmd LC_LOAD_WEAK_DYLIB
                  cmdsize 96
                     name /System/Library/Frameworks/Translation.framework/Versions/A/Translation (offset 24)
            Load command 14
                      cmd LC_LOAD_DYLIB
                  cmdsize 56
                     name /usr/lib/libSystem.B.dylib (offset 24)
            Load command 15
                      cmd LC_LOAD_DYLIB
                     name /System/Library/Frameworks/Translation.framework/Versions/A/Translation (offset 24)
            """
        let loads = BundleCheck.frameworkLoads(inLoadCommands: output)
        #expect(loads == ["AppKit": [false], "Translation": [true, false]])
    }

    @Test func aBundleMissingAnArchitectureFails() throws {
        var fake = FakeBundle()
        fake.universalApp = false
        let result = try checks(fake)
        #expect(result["bundle-structure.archs"]?.ok == false)
        #expect(result["bundle-structure.archs"]?.detail.contains("x86_64") == true)
        #expect(result["bundle-structure.signature"]?.ok == true)

        var thinAppex = FakeBundle()
        thinAppex.universalAppex = false
        #expect(try checks(thinAppex)["bundle-structure.archs"]?.ok == false)
    }

    @Test func aBundleWithChangedEntitlementsFails() throws {
        var app = FakeBundle()
        app.appEntitlements = #"<key>com.apple.security.app-sandbox</key><true/>"#
        let appResult = try checks(app)
        #expect(appResult["bundle-structure.entitlements"]?.ok == false)
        #expect(appResult["bundle-structure.entitlements"]?.detail.contains("Pomelo.entitlements") == true)

        var appex = FakeBundle()
        appex.appexEntitlements = #"<key>com.apple.security.app-sandbox</key><false/>"#
        let appexResult = try checks(appex)
        #expect(appexResult["bundle-structure.entitlements"]?.ok == false)
        #expect(appexResult["bundle-structure.entitlements"]?.detail.contains("PomeloQuickAction.entitlements") == true)
    }

    @Test func aReleaseBundleThatADebuggerCanAttachToFails() throws {
        let getTaskAllow = #"<key>com.apple.security.get-task-allow</key><true/>"#
        var app = FakeBundle()
        app.appEntitlements += getTaskAllow
        let appResult = try checks(app)
        #expect(appResult["bundle-structure.entitlements"]?.ok == false)
        #expect(appResult["bundle-structure.entitlements"]?.detail.contains("Fake.app carries com.apple.security.get-task-allow") == true)

        var appex = FakeBundle()
        appex.appexEntitlements += getTaskAllow
        let appexResult = try checks(appex)
        #expect(appexResult["bundle-structure.entitlements"]?.ok == false)
        #expect(appexResult["bundle-structure.entitlements"]?.detail.contains("PomeloQuickAction.appex carries com.apple.security.get-task-allow") == true)
    }

    @Test func aDebugBundleMayCarryTheDebugSigningEntitlement() throws {
        var fake = FakeBundle()
        fake.appEntitlements += #"<key>com.apple.security.get-task-allow</key><true/>"#
        fake.appexEntitlements += #"<key>com.apple.security.get-task-allow</key><true/>"#
        #expect(try checks(fake, configuration: .debug)["bundle-structure.entitlements"]?.ok == true)
    }

    @Test func aReleaseBundleWithoutTheHardenedRuntimeFails() throws {
        var app = FakeBundle()
        app.appHardenedRuntime = false
        let appResult = try checks(app)
        #expect(appResult["bundle-structure.hardened-runtime"]?.ok == false)
        #expect(appResult["bundle-structure.hardened-runtime"]?.detail.contains("Fake.app") == true)
        #expect(appResult["bundle-structure.signature"]?.ok == true)

        var appex = FakeBundle()
        appex.appexHardenedRuntime = false
        let appexResult = try checks(appex)
        #expect(appexResult["bundle-structure.hardened-runtime"]?.ok == false)
        #expect(appexResult["bundle-structure.hardened-runtime"]?.detail.contains("PomeloQuickAction.appex") == true)
    }

    /// Xcode's Debug builds come out signed without the runtime flag, like the get-task-allow they carry.
    @Test func aDebugBundleMayLackTheHardenedRuntime() throws {
        var fake = FakeBundle()
        fake.appHardenedRuntime = false
        fake.appexHardenedRuntime = false
        #expect(try checks(fake, configuration: .debug)["bundle-structure.hardened-runtime"]?.ok == true)
    }

    @Test func anUnsignedOrTamperedBundleFailsTheSignature() throws {
        var unsigned = FakeBundle()
        unsigned.sign = false
        #expect(try checks(unsigned)["bundle-structure.signature"]?.ok == false)

        var tampered = FakeBundle()
        tampered.tamperAfterSigning = true
        #expect(try checks(tampered)["bundle-structure.signature"]?.ok == false)
    }

    @Test func aMissingAppexOrAppIntentsMetadataFails() throws {
        var noAppex = FakeBundle()
        noAppex.appexPresent = false
        let appexResult = try checks(noAppex)
        #expect(appexResult["bundle-structure.appex"]?.ok == false)
        #expect(appexResult["bundle-structure.archs"]?.ok == false)

        var noIntents = FakeBundle()
        noIntents.appIntentsPresent = false
        #expect(try checks(noIntents)["bundle-structure.appintents"]?.ok == false)
    }
}
