# Pomelo user guide

## The wheel

Drag files in Finder and tap **⇧** while you drag. A wheel opens at the cursor:

- **Convert** shows the formats the files can become, most common first.
- Tap ⇧ again for **Tools**: instant jobs, editors, and the AI page for the kinds of file that have one.
- Drop the files on a slice to run it. Each result appears next to its original with a new name; nothing is ever
  overwritten.
- Drop anywhere else, or press Esc, and the drag goes on as usual.

The centre of the wheel (the hub) estimates the result's size ("About 1.2 MB, 64% smaller") and turns red when a file
is damaged or a job fails quickly. A failure stays until you click elsewhere or move away. A long job (a video, say)
shows Finder's own progress on each file, and Finder's cancel button stops it. A small pill at the drop point shows the
progress of a long job and reports a failure the wheel was no longer there to show. Quitting Pomelo stops every job
still running.

**Without dragging.** Select files in Finder and press **⌥⌘K** (click mode; macOS asks once to let Pomelo read
Finder's selection). The *Convert with Pomelo* Quick Action, the *Convert with Pomelo…* item in Finder's Services
menu, `open -a Pomelo photo.png` and dropping files on Pomelo's icon all open the same wheel. Pomelo never becomes the
default app for any file type.

## Tools

What each kind of file shows by default (Settings › Wheel changes all of it). Every Tools page ends with the Shelf.

- **Images**: Crop…, Compress, Compress to size…, Resize…, Rotate…, Redact…, Combine into PDF. AI page: Remove
  background, Smart crop, Straighten document, Scan to Markdown, Extract tables, Extract data, Find duplicates.
- **Videos**: Trim…, Crop…, Compress, Compress to size…, Rotate…, Extract audio, Remove audio. AI page: Transcribe,
  Make subtitles.
- **Audio**: Trim…, Normalize volume, Speed 2×, Speed 0.5×, Mono, Remove metadata, Make Zip. AI page: Transcribe,
  Make subtitles.
- **PDFs**: Compress, Compress to size…, Read codes (QR and barcodes, to the clipboard), Merge PDFs, Split PDF,
  Organize pages…, Make Zip. AI page: Summarize, Scan to Markdown, Extract tables, Extract data.
- **Archives**: Extract (zip, tar, tgz, gz; RAR with `unar`).
- **Documents, text, data, subtitles and other files**: Make Zip, Copy Paths, Copy Files, Show in Finder, Open in
  Terminal; Translate and Summarize where they apply.

A few more are one drag away in Settings › Wheel: Compress more, Half size, Split… for videos, Snapshot, Read codes
for images, and Remove metadata for images and videos.

**Editors** (the tools whose name ends in "…") open a compact panel at the drop point: Trim, Split, Crop, Resize,
Rotate, Compress to size (pick a size, Pomelo finds the quality), Redact (Pomelo proposes faces, email addresses and
lines of text using Vision; you choose what to cover, and the result is checked so nothing of the original survives)
and Organize pages (reorder, rotate and delete PDF pages).

**On-device intelligence.** Smart crop (with a choice of shape), Straighten document and Find duplicates (writes a text
report; it never moves or deletes anything) use Vision. On macOS 26: Transcribe and Make subtitles (Apple's speech
recognizer; a missing language is downloaded by macOS), Translate (installed languages only), Scan to Markdown,
Extract tables (to CSV or Excel) and PDF to Word read documents with Vision. With Apple Intelligence turned on,
Summarize and Extract data use Apple's on-device model. Nothing leaves your Mac.

**Settings › Tools** sets each tool's options: quality, size, speed, the language of a transcription or translation,
and more. **Replace the original** (off by default) moves an original to the Trash once its result is in place, and
the result takes its name: after a conversion that keeps the kind of file (HEIC to JPG, MOV to MP4), an editor (Crop,
Trim, Resize…) or a tool (Compress, Remove background…). It never applies when part of the file would be lost (a
video's audio, a transcript, a PSD's layers, an animated GIF's frames, a document's export), when the new name is
already taken, to a merge, or when there are several results.

## Your own wheel

**Settings › Wheel** shows the wheel itself, exactly as it looks in use. Pick a kind of file on the left (images,
videos, PDFs, …), or a single format, and drag pieces from the list on the right onto its slices, between its pages, or
off the wheel to remove them. A wheel has one to four pages of up to eight slices, and you can rename every page.
⌘Z undoes. The built-in wheels adapt to the files you drag; a wheel you customize stays exactly as you made it, and a
slice that can't run on the files you drag is greyed out with the reason.

## The Shelf

The Shelf holds files for later: gather them from several folders, then drag them all out at once.

- **Open it** by shaking the pointer left and right while you drag files (sensitivity in Settings › General, "Shake
  to open the Shelf"), from the Shelf slice on the Tools page, or with Show Shelf in the menu.
- Drag files out to copy them; hold **⌘** to move them instead, as in Finder. Quick Look, keys and a context menu work
  on the list.
- Run a tool on files from the Shelf and the results take their place on it.
- Tuck the Shelf into a tab at the screen's edge, or move it by its header. It forgets its files when Pomelo quits
  (the files themselves are never touched).

## Shortcuts

Pomelo adds two actions to the Shortcuts app: **Convert Files** (files and a format) and **Run a Tool** (files and a
tool; the editors aren't available). They run inside the menu-bar app, which Shortcuts starts when needed, and they
never replace an original. The outputs come back in input order, so the next action can use them. A file already in
the target format, or one a tool doesn't apply to, is passed on as it is. If a file fails, the action stops with a
sentence ("2 of 3 converted. bad.png may be damaged.") and the files that did convert stay next to their originals.
Spotlight finds "Convert files with Pomelo" and "Run a Pomelo tool".

## The Finder Quick Action

*Convert with Pomelo* appears in Finder's Quick Actions menu and the Preview pane and opens the wheel on the selected
files. macOS registers it from the copy of Pomelo in `/Applications`: open Pomelo from there once, then turn on
"Convert with Pomelo" in System Settings › General › Login Items & Extensions (under Finder or Actions). If it never
appears, the Services menu item does the same.

## Watch folders

**Settings › Watch Folders**: add a folder and choose a format to convert to, or a tool. Every file that arrives is
processed next to itself once it has settled (a second of steady size, fully downloaded or copied). A rule takes every
file it can handle: "Convert to JPEG" also makes a JPEG of each PDF that arrives. Files already in the folder, or that
arrived while Pomelo wasn't running, are left alone, and a watch folder never replaces an original. Everything Pomelo
makes carries a hidden mark (the extended attribute `io.github.pomelo-app.output`), so a result is never converted
again. Folders on network drives notice only files added from this Mac.

## Engines

Pomelo uses Apple's frameworks for most work. **Settings › Engines** lists the optional engines and what each one
adds:

- **FFmpeg, cwebp, Pandoc and pngquant** have an Install button. Pomelo downloads the publisher's build over https,
  checks it against a SHA-256 fingerprint kept in Pomelo, and only then installs it into
  `~/Library/Application Support/Pomelo/Engines`, for Pomelo only. A mismatch installs nothing.
- **The Unarchiver** (`brew install unar`) and **LibreOffice** (`brew install --cask libreoffice`) install with
  Homebrew.

Engines installed with Homebrew work too.

## Plugins

An engine is described by a JSON manifest. Put your own `*.pomelo-plugin.json` files in
`~/Library/Application Support/Pomelo/Plugins` to teach Pomelo new conversions with any command-line tool; the
built-in manifests in `Sources/PomeloEngines/Plugins` are working examples.

## Troubleshooting

- **The wheel doesn't open when I tap ⇧.** Make sure Pomelo is running (its icon is in the menu bar) and that you tap
  ⇧ while the drag is still going.
- **macOS says Pomelo can't be opened.** See [Install](../README.md#install): Pomelo isn't notarized.
- **macOS asks whether Pomelo may access Downloads (or Desktop, Documents…).** Pomelo saves each result next to its
  original, so macOS asks once per protected folder. If you clicked Don't Allow, conversions in that folder fail: turn
  Pomelo back on in System Settings › Privacy & Security › Files and Folders.
- **A conversion is missing.** It may need an engine: Settings › Engines, or `pomelo engines` in Terminal, says which.
