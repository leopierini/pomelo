# Developing Pomelo

## Layout

| Path | What's there |
|---|---|
| `Sources/PomeloCore` | Formats, route planning, jobs, output safety (staging and publishing), plugin manifests, presets |
| `Sources/PomeloEngines` | The engines: ImageIO, PDFKit, AVFoundation, Vision, Speech, Translation, the on-device model, archives, spreadsheets, and the external tools described by `Plugins/*.pomelo-plugin.json` |
| `Sources/PomeloUIModel` | What the wheel shows: pages, tools, the custom wheel, settings |
| `Sources/PomeloCLIKit`, `Sources/pomelo` | The `pomelo` command-line tool |
| `Sources/PomeloEvalsKit`, `Sources/PomeloEvals` | `pomelo-evals`, the measurement tool behind `evals/` |
| `Sources/PomeloTestSupport` | Generated fixtures shared by the tests and the evals |
| `App/` | The menu-bar app (an XcodeGen project): drag detection, the wheel, editors, the Shelf, settings, watch folders, App Intents and the Finder Quick Action |
| `evals/` | The measurement harness and its baseline |
| `scripts/` | Icon generation, the release script and `make-gif.sh` (screen recordings to README GIFs) |

## Build and test

Build products go outside the repository (`--scratch-path`, `-derivedDataPath`): in an iCloud-synced folder such as
`~/Desktop`, test bundles built in an in-repo `.build` fail code signing.

```sh
swift build --scratch-path ~/Library/Caches/Pomelo-build
swift test  --scratch-path ~/Library/Caches/Pomelo-build [--filter <Suite>]

brew install xcodegen                                   # once
cd App && xcodegen generate && cd ..                    # again after adding or removing files
xcodebuild -project App/Pomelo.xcodeproj -scheme Pomelo -configuration Debug \
  -derivedDataPath ~/Library/Caches/Pomelo-build/xcode build    # `test` runs the app tests
```

Building needs Xcode 27 or later: Xcode 26's compiler hangs on the package. (Translation also needs an app linked
against SDK 26.4 or later, or it answers as if no language were installed.)

The tests never touch your real state: they use in-memory defaults, a private pasteboard, temporary folders and
off-screen windows, and stub the external engines that aren't installed.

## Measurements

`evals/run.sh --quick` measures conversion speed and output quality per conversion, wheel open time, launch time, idle
CPU and memory, and sizes, and compares them with `evals/baseline.json`. Every metric has a budget. The full
`evals/run.sh` adds clean builds, warning counts, the test suites and a code-health audit (`evals/audit.sh`: Periphery,
jscpd, lizard). `evals/flaky.sh [runs]` reruns the tests to catch flaky ones. The measured app never reads `~/Desktop`,
`~/Documents`, `~/Downloads` or iCloud Drive: `evals/run.sh` copies what it needs into a temporary folder.

## Rules the code keeps

- **Never modify a source file.** Outputs are staged and published with `renamex_np(RENAME_EXCL)`, so nothing is ever
  overwritten. Anything removed goes to the Trash.
- **The wheel opens within 50 ms** of the trigger: nothing slow runs synchronously when it opens.
- **No permissions for the gesture**: global mouse monitors plus drag-pasteboard polling, never key monitors or event
  taps.
- **One dependency**: `swift-argument-parser`, for the command-line tools.
- **Every output carries the `io.github.pomelo-app.output` mark**, so watch folders never convert a result again.
- **UI text never uses "·" or "—" as a separator**: use two labels or a plain sentence.

Some comments cite design decisions by number (P23, S12, …) from the project's design log.

## Releasing

`scripts/release.sh` builds the Release app into `~/Library/Caches/Pomelo-build`, signs it with the maintainer's
"Pomelo" code-signing certificate, and writes `Pomelo-<version>.zip` and its SHA-256 to
`~/Library/Caches/Pomelo-build/release/`. Attach both to a GitHub release. macOS ties the folder permissions a user
grants to the app's signature, so every release must be signed with the same certificate, or users are asked again
after updating. `scripts/release.sh --ad-hoc` builds a zip without it.
