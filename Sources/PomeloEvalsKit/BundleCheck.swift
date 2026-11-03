import Foundation

/// Structural checks of a built Pomelo.app that a size or timing number can't catch: both architectures in both
/// binaries, an intact signature with the hardened runtime, the entitlements the project files declare, the Quick
/// Action and App Intents metadata, the macOS 26 frameworks loaded weakly and the SDK the binaries are linked with.
/// Phase 7's CI gates on these.
public enum BundleCheck {
    static let architectures = ["arm64", "x86_64"]
    static let appexPath = "Contents/PlugIns/PomeloQuickAction.appex"
    static let appIntentsPath = "Contents/Resources/Metadata.appintents"
    /// Xcode's development signing adds it, so a debugger can attach. Tolerated on Debug only: a shipped
    /// hardened-runtime build must not be debuggable by any process (P144).
    static let getTaskAllow = "com.apple.security.get-task-allow"
    /// Frameworks that exist only on macOS 26: a strong load would stop the app launching on macOS 14 and 15.
    static let weakFrameworks = ["FoundationModels", "Translation"]

    /// Translation answers a binary linked against an older SDK as if no language were installed (P163).
    static let minimumSDK = [26, 4]

    /// `expectedEntitlements` is the folder holding `Pomelo.entitlements` and `PomeloQuickAction.entitlements` (`App/`).
    public enum Configuration: String, Sendable, CaseIterable { case release, debug }

    /// `cli` is the built `pomelo` executable, checked for its SDK too when given.
    public static func run(
        app: URL, expectedEntitlements: URL, configuration: Configuration = .release, cli: URL? = nil
    ) -> [EvalResults.Check] {
        let appex = app.appending(path: appexPath, directoryHint: .isDirectory)
        return [
            archsCheck(app: app, appex: appex),
            signatureCheck(app: app),
            entitlementsCheck(app: app, appex: appex, expected: expectedEntitlements, configuration: configuration),
            existsCheck("bundle-structure.appex", appex, "the Quick Action extension"),
            existsCheck("bundle-structure.appintents", app.appending(path: appIntentsPath), "the App Intents metadata"),
            hardenedRuntimeCheck(app: app, appex: appex, configuration: configuration),
            weakLinksCheck(app: app),
            sdkCheck(app: app, cli: cli),
        ]
    }

    /// `otool -l` of the app's executable, and of the `<name>.debug.dylib` beside it that holds a Debug build's code.
    /// Passes vacuously for a framework nothing links yet.
    private static func weakLinksCheck(app: URL) -> EvalResults.Check {
        guard let binary = executable(of: app) else {
            return make("bundle-structure.weak-links", ["app has no executable"], ok: "")
        }
        var loads: [String: Set<Bool>] = [:]
        var problems: [String] = []
        for file in machOFiles(of: binary) {
            guard let commands = loadCommands(of: file) else { problems.append("otool failed on \(file.lastPathComponent)"); continue }
            loads.merge(frameworkLoads(inLoadCommands: commands)) { $0.union($1) }
        }
        var weak: [String] = []
        var unlinked: [String] = []
        for framework in weakFrameworks {
            switch loads[framework] {
            case nil: unlinked.append(framework)
            case let kinds? where kinds.contains(false): problems.append("\(framework) is linked strongly")
            default: weak.append(framework)
            }
        }
        var ok: [String] = []
        if !weak.isEmpty {
            ok.append("\(weak.joined(separator: " and ")) \(weak.count == 1 ? "loads" : "load") weakly")
        }
        if !unlinked.isEmpty {
            ok.append("\(unlinked.joined(separator: " and ")) \(unlinked.count == 1 ? "is" : "are") not linked yet")
        }
        return make("bundle-structure.weak-links", problems, ok: ok.joined(separator: "; "))
    }

    /// `binary` and, for a Debug build, the `<name>.debug.dylib` beside it that holds the app's code.
    private static func machOFiles(of binary: URL) -> [URL] {
        let debugDylib = binary.appendingPathExtension("debug.dylib")
        return [binary] + (FileManager.default.fileExists(atPath: debugDylib.path) ? [debugDylib] : [])
    }

    private static func loadCommands(of file: URL) -> String? {
        let result = Shell.run("/usr/bin/otool", ["-l", file.path])
        return result.status == 0 ? result.output : nil
    }

    /// The SDK each binary claims to be linked against (`LC_BUILD_VERSION`'s `sdk`), at least `minimumSDK`: the
    /// behaviour of Translation is decided by it, not by the OS the binary runs on (P163). A Debug app's code lives in
    /// the `<name>.debug.dylib` beside the stub executable, which carries its own.
    private static func sdkCheck(app: URL, cli: URL?) -> EvalResults.Check {
        var files: [(label: String, url: URL)] = []
        if let binary = executable(of: app) {
            files += machOFiles(of: binary).map { ($0 == binary ? "the app" : "the app's debug dylib", $0) }
        }
        if let cli { files.append(("the CLI", cli)) }
        var problems: [String] = []
        var found: [String] = []
        for (label, file) in files {
            guard let commands = loadCommands(of: file) else { problems.append("otool failed on \(file.lastPathComponent)"); continue }
            let sdks = sdkVersions(inLoadCommands: commands)
            guard let lowest = sdks.min(by: { $0.lexicographicallyPrecedes($1) }) else {
                problems.append("\(label) states no SDK")
                continue
            }
            let text = lowest.map(String.init).joined(separator: ".")
            if lowest.lexicographicallyPrecedes(minimumSDK) {
                problems.append("\(label) is linked against SDK \(text), Translation needs \(minimumSDK.map(String.init).joined(separator: ".")) or later")
            } else {
                found.append("\(label) SDK \(text)")
            }
        }
        if files.isEmpty { problems.append("app has no executable") }
        return make("bundle-structure.sdk", problems, ok: found.joined(separator: ", "))
    }

    /// The fields of every `otool -l` line, each with the load command it sits in.
    private static func fields(inLoadCommands output: String) -> [(command: String, fields: [Substring])] {
        var command = ""
        var lines: [(command: String, fields: [Substring])] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 2 else { continue }
            if fields[0] == "cmd" { command = String(fields[1]); continue }
            lines.append((command, fields))
        }
        return lines
    }

    /// Every `sdk` of a `LC_BUILD_VERSION` or `LC_VERSION_MIN_MACOSX` command in `otool -l` output (one per
    /// architecture of a universal binary), as numbers.
    static func sdkVersions(inLoadCommands output: String) -> [[Int]] {
        fields(inLoadCommands: output).compactMap { command, fields in
            guard fields[0] == "sdk", command == "LC_BUILD_VERSION" || command == "LC_VERSION_MIN_MACOSX" else { return nil }
            let numbers = fields[1].split(separator: ".").compactMap { Int($0) }
            return numbers.isEmpty ? nil : numbers
        }
    }

    /// Each framework `otool -l` lists, with whether each of its loads is weak (every architecture of a universal
    /// binary is listed).
    static func frameworkLoads(inLoadCommands output: String) -> [String: Set<Bool>] {
        var loads: [String: Set<Bool>] = [:]
        for (command, fields) in fields(inLoadCommands: output) {
            guard fields[0] == "name", command.hasSuffix("_DYLIB"), let at = fields[1].range(of: ".framework/") else {
                continue
            }
            let framework = fields[1][..<at.lowerBound].split(separator: "/").last.map(String.init) ?? ""
            loads[framework, default: []].insert(command == "LC_LOAD_WEAK_DYLIB")
        }
        return loads
    }

    private static func archsCheck(app: URL, appex: URL) -> EvalResults.Check {
        var problems: [String] = []
        for (label, bundle) in [("app", app), ("appex", appex)] {
            guard let binary = executable(of: bundle) else { problems.append("\(label) has no executable"); continue }
            let result = Shell.run("/usr/bin/lipo", ["-archs", binary.path])
            guard result.status == 0 else { problems.append("\(label): lipo failed: \(result.errorOutput)"); continue }
            let found = result.output.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            let missing = architectures.filter { !found.contains($0) }
            if !missing.isEmpty { problems.append("\(label) is missing \(missing.joined(separator: ", "))") }
        }
        return make("bundle-structure.archs", problems, ok: "app and appex have \(architectures.joined(separator: " and "))")
    }

    private static func signatureCheck(app: URL) -> EvalResults.Check {
        let result = Shell.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        let detail = result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return make("bundle-structure.signature", result.status == 0 ? [] : [detail.isEmpty ? "codesign failed" : detail],
                    ok: "codesign --verify --deep --strict passes")
    }

    /// `ENABLE_HARDENED_RUNTIME` in `App/project.yml`. Xcode's Debug builds come out signed without it, so only a
    /// Release build must show it.
    private static func hardenedRuntimeCheck(app: URL, appex: URL, configuration: Configuration) -> EvalResults.Check {
        guard configuration == .release else {
            return make("bundle-structure.hardened-runtime", [], ok: "not required of a Debug build")
        }
        var problems: [String] = []
        for bundle in [app, appex] {
            // `codesign -dv` writes `CodeDirectory v=… flags=0x10002(adhoc,runtime) …` to stderr.
            let result = Shell.run("/usr/bin/codesign", ["-dv", bundle.path])
            let flags = result.errorOutput.split(whereSeparator: \.isWhitespace).first { $0.hasPrefix("flags=") }
            guard let flags else {
                problems.append("cannot read the signature flags of \(bundle.lastPathComponent)")
                continue
            }
            if !flags.contains("runtime") {
                problems.append("\(bundle.lastPathComponent) is signed without the hardened runtime (\(flags))")
            }
        }
        return make("bundle-structure.hardened-runtime", problems,
                    ok: "app and appex are signed with the hardened runtime")
    }

    private static func entitlementsCheck(
        app: URL, appex: URL, expected: URL, configuration: Configuration
    ) -> EvalResults.Check {
        var problems: [String] = []
        for (bundle, file) in [(app, "Pomelo.entitlements"), (appex, "PomeloQuickAction.entitlements")] {
            let name = bundle.lastPathComponent
            guard let wanted = plist(from: try? Data(contentsOf: expected.appending(path: file))) else {
                problems.append("cannot read \(file)")
                continue
            }
            let signed = Shell.run("/usr/bin/codesign", ["-d", "--entitlements", ":-", bundle.path])
            // A bundle signed with no entitlements prints nothing: an empty dictionary, not an unreadable one.
            let actual = signed.output.isEmpty ? [:] : plist(from: Data(signed.output.utf8))
            guard var actual else { problems.append("cannot read the entitlements of \(name)"); continue }
            if actual.removeValue(forKey: getTaskAllow) != nil, configuration == .release {
                problems.append("\(name) carries \(getTaskAllow): a Release build must not be debuggable")
            }
            if NSDictionary(dictionary: actual) != NSDictionary(dictionary: wanted) {
                problems.append("\(name) is signed with \(describe(actual)), \(file) declares \(describe(wanted))")
            }
        }
        return make("bundle-structure.entitlements", problems, ok: "app and appex entitlements match App/*.entitlements")
    }

    private static func existsCheck(_ name: String, _ url: URL, _ what: String) -> EvalResults.Check {
        let exists = FileManager.default.fileExists(atPath: url.path)
        return make(name, exists ? [] : ["\(what) is missing at \(url.path)"], ok: "\(what) is present")
    }

    private static func make(_ name: String, _ problems: [String], ok: String) -> EvalResults.Check {
        EvalResults.Check(name: name, ok: problems.isEmpty, detail: problems.isEmpty ? ok : problems.joined(separator: "; "))
    }

    private static func executable(of bundle: URL) -> URL? {
        guard let info = plist(from: try? Data(contentsOf: bundle.appending(path: "Contents/Info.plist"))),
              let name = info["CFBundleExecutable"] as? String else { return nil }
        let url = bundle.appending(path: "Contents/MacOS/\(name)")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func plist(from data: Data?) -> [String: Any]? {
        guard let data else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    private static func describe(_ entitlements: [String: Any]) -> String {
        entitlements.isEmpty ? "none" : entitlements.keys.sorted().map { "\($0)=\(entitlements[$0]!)" }.joined(separator: ", ")
    }
}

enum Shell {
    struct Result {
        var status: Int32
        var output: String
        var errorOutput: String
    }

    /// Runs a tool whose output is small (lipo, codesign): stdout is drained first, then stderr.
    static func run(_ tool: String, _ arguments: [String]) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        guard (try? process.run()) != nil else { return Result(status: -1, output: "", errorOutput: "cannot run \(tool)") }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(status: process.terminationStatus, output: String(decoding: outData, as: UTF8.self),
                      errorOutput: String(decoding: errData, as: UTF8.self))
    }
}
