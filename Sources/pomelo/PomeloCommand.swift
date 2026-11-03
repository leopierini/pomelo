import ArgumentParser
import Foundation
import PomeloCLIKit
import PomeloCore
import PomeloEngines

@main
struct PomeloCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pomelo",
        abstract: "Convert files between formats.",
        subcommands: [Convert.self, Targets.self, Engines.self, Routes.self]
    )

    /// Like ArgumentParser's own `main()`, with two differences:
    ///
    /// - every usage error exits 2 (spec §3.7), where ArgumentParser would exit 64 for a malformed command line;
    ///   `--help` still exits 0;
    /// - the subcommand runs in a task that SIGINT, SIGTERM and SIGHUP cancel. The command then winds down as it
    ///   would on any cancellation (external tools' process groups are killed, staging folders removed) and the
    ///   process exits 130, 143 or 129. A second signal during that clean-up exits at once.
    static func main() async {
        let command: any ParsableCommand
        do {
            command = try parseAsRoot()
        } catch {
            exit(for: error)
        }
        let work = Task.detached {
            var command = command
            if var asyncCommand = command as? any AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
        }
        let interruption = Interruption(cancelling: work)
        let result = await work.result
        if let code = interruption.exitCode { Foundation.exit(code) }
        if case .failure(let error) = result { exit(for: error) }
    }

    private static func exit(for error: any Error) -> Never {
        if exitCode(for: error) == .validationFailure {
            FileHandle.standardError.write(Data((fullMessage(for: error) + "\n").utf8))
            Foundation.exit(2)
        }
        exit(withError: error)
    }
}

/// Turns SIGINT, SIGTERM and SIGHUP into cancellation of `task`, remembering the exit code the first signal calls
/// for (128 + the signal number). The signals are ignored by default and delivered through dispatch sources instead,
/// so no async-signal-safety rules apply in the handlers. Children start with default dispositions (`ProcessRunner`
/// resets them).
private final class Interruption: @unchecked Sendable {
    private static let signals: [Int32] = [SIGINT, SIGTERM, SIGHUP]

    private let lock = NSLock()
    private var received: Int32?
    private var sources: [any DispatchSourceSignal] = []

    init(cancelling task: Task<Void, any Error>) {
        for signalNumber in Self.signals {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
            source.setEventHandler { [self] in
                let code = 128 + signalNumber
                let isFirst = lock.withLock {
                    guard received == nil else { return false }
                    received = code
                    return true
                }
                if isFirst { task.cancel() } else { Foundation.exit(code) }
            }
            source.resume()
            sources.append(source)
        }
    }

    /// 128 + the first signal received, or nil if none arrived.
    var exitCode: Int32? {
        lock.withLock { received }
    }
}

private func makeRegistry() -> EngineRegistry {
    DefaultEngines.makeRegistry(userPluginsFolder: DefaultEngines.userPluginsFolder)
}

/// Prints the output and, when the exit code is not 0, exits with it.
private func finish(_ output: CLIOutput) throws {
    print(output.stdout)
    if output.exitCode != 0 { throw ExitCode(output.exitCode) }
}

struct Convert: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Convert files to another format or with a preset.")

    @Argument(help: "The files to convert.") var files: [String] = []
    @Option(name: .long, help: "Target format, e.g. jpg.") var to: String?
    @Option(name: .long, help: "Preset id, e.g. half-size.") var preset: String?
    @Option(
        name: .long,
        help: "A JSON object of preset options, laid over the preset's own (e.g. '{\"targetBytes\":5000000}'); see docs/cli-json.md."
    ) var options: String?
    @Option(name: [.customShort("o"), .long], help: "Write outputs into this folder instead of next to each source.")
    var outputDir: String?
    @Flag(name: .long, help: "Print machine-readable JSON.") var json = false

    func run() async throws {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let output = await CLICommands.convert(
            files: files.map { URL(fileURLWithPath: $0) }, to: to, preset: preset, options: options,
            outputDir: outputDir.map { URL(fileURLWithPath: $0, isDirectory: true) },
            registry: makeRegistry(), downloads: downloads, json: json
        )
        try finish(output)
    }
}

struct Targets: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List the formats a file can be converted to.")

    @Argument(help: "The file to inspect.") var file: String
    @Flag(name: .long, help: "Print machine-readable JSON.") var json = false

    func run() async throws {
        try finish(await CLICommands.targets(file: URL(fileURLWithPath: file), registry: makeRegistry(), json: json))
    }
}

struct Engines: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show which conversion engines are available.")

    @Flag(name: .long, help: "Print machine-readable JSON.") var json = false

    func run() async throws {
        let failures = DefaultEngines.loadPlugins(userPluginsFolder: DefaultEngines.userPluginsFolder).failures
        try finish(await CLICommands.engines(registry: makeRegistry(), json: json, pluginFailures: failures))
    }
}

struct Routes: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show the conversion route between two formats.")

    @Argument(help: "Source format, e.g. png.") var from: String
    @Argument(help: "Target format, e.g. webp.") var to: String
    @Flag(name: .long, help: "Print machine-readable JSON.") var json = false

    func run() async throws {
        try finish(await CLICommands.routes(from: from, to: to, registry: makeRegistry(), json: json))
    }
}
