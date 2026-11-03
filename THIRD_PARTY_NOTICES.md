# Third-party notices

## Code built into Pomelo

The app itself uses only Apple's frameworks. The `pomelo` command-line tool and the `pomelo-evals` harness also link:

| Component | License | Source |
|---|---|---|
| Swift Argument Parser | Apache License 2.0 | https://github.com/apple/swift-argument-parser |

Swift Argument Parser is Copyright (c) Apple Inc. and the Swift project authors, licensed under the Apache License,
Version 2.0 (https://www.apache.org/licenses/LICENSE-2.0) with the Runtime Library Exception.

## Engines Pomelo can run (not included)

Some conversions use free command-line programs installed on your Mac. Pomelo does not bundle them: it finds them
where Homebrew installs them, or, when you click Install in Settings › Engines, downloads the publisher's own build
over https, checks it against a SHA-256 fingerprint kept in Pomelo, and installs it into
`~/Library/Application Support/Pomelo/Engines` for Pomelo's own use. Each program stays under its own license and
runs as a separate process.

| Engine | Used for | License | Project |
|---|---|---|---|
| FFmpeg | most video and audio conversions | LGPL 2.1+ or GPL 2+, depending on the build | https://ffmpeg.org |
| cwebp (libwebp) | WebP output | BSD 3-Clause | https://developers.google.com/speed/webp |
| Pandoc | document conversions (Markdown, EPUB, Word, …) | GPL 2+ | https://pandoc.org |
| pngquant | lossy PNG compression | GPL 3+ | https://pngquant.org |
| The Unarchiver (`unar`) | RAR extraction | LGPL 2.1 | https://theunarchiver.com/command-line |
| LibreOffice | legacy Office formats and slides | MPL 2.0 | https://www.libreoffice.org |

The one-click FFmpeg install uses Martin Riedl's static macOS builds (https://ffmpeg.martin-riedl.de).

## Test fixture

`Tests/PomeloEnginesTests/Resources/face.jpg` is NASA's portrait of Neil Armstrong (photo S69-31741, 1969), a work
of NASA in the public domain, from https://commons.wikimedia.org/wiki/File:Neil_Armstrong_pose.jpg.

## Acknowledgements

Pomelo learned from these MIT-licensed projects:

- [Filee](https://github.com/KnifeLemon/Filee): route planning and output-safety ideas.
- [ShiftDrop](https://github.com/dcatmakas/ShiftDrop): the permission-free way to notice a Finder drag.
