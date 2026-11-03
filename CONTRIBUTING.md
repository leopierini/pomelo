# Contributing to Pomelo

Thanks for helping! Pomelo is a small project maintained in spare time, so a short, focused change is the easiest to
review.

## Reporting bugs and ideas

Open an [issue](https://github.com/leopierini/pomelo/issues/new/choose). For a bug, say which macOS version you're on,
what you dragged (the format and roughly the size), what you expected and what happened. If a conversion failed,
`pomelo convert <file> --to <format>` in Terminal often prints a more precise reason.

## Pull requests

1. Open an issue first for anything bigger than a small fix, so we can agree on the approach.
2. Read [docs/development.md](docs/development.md): how to build, test and measure, and the rules the code keeps
   (above all: never modify a source file, and no permissions for the gesture).
3. Add a test that fails without your change.
4. Before you push, run the tests and the quick measurements:

   ```sh
   swift test --scratch-path ~/Library/Caches/Pomelo-build
   xcodebuild -project App/Pomelo.xcodeproj -scheme Pomelo -configuration Debug \
     -derivedDataPath ~/Library/Caches/Pomelo-build/xcode test
   evals/run.sh --quick
   ```

5. Keep comments for the *why*, not the *what*, and write UI text as plain sentences.

New third-party dependencies are unlikely to be accepted: Pomelo depends only on `swift-argument-parser`. A new
external engine can usually be added as a plugin manifest instead (see `Sources/PomeloEngines/Plugins`).

By contributing, you agree that your contribution is licensed under the [MIT License](LICENSE).
