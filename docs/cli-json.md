# `pomelo --json` schema

Every subcommand takes `--json` and then prints one JSON document to stdout. Scripts and agents can rely on this
shape.

- Keys are sorted alphabetically, and the output is pretty-printed.
- Optional fields are never omitted. When they have no value they are an explicit `null`, so `result["note"]` always
  exists.
- Paths are absolute path strings.
- Exit codes:
  - `0`: everything succeeded.
  - `1`: at least one file failed or was cancelled (`convert`), or there is no route (`routes`).
  - `2`: usage error, including a malformed command line: no files, unknown `--to` format, unknown preset id,
    neither or both of `--to` and `--preset`, an `-o` folder that does not exist or is not a folder, `targets` on a
    file of unknown format, `routes` with an unknown format, `--options` that is not a JSON object or holds an
    unknown edit kind, an editor preset without `edit` or `targetBytes`, an `outputFormat` the preset can't make. A
    missing input file is not a usage error: that file fails with status `"failed"` and the exit code is `1`.
  - `130`, `143`, `129`: interrupted by SIGINT, SIGTERM or SIGHUP. Running conversions are cancelled first (external
    tools are stopped, nothing partial is left behind); `convert` still prints its results, with the interrupted
    files as `"cancelled"`. A second signal during that clean-up exits immediately.

## `pomelo convert <files…> (--to <format> | --preset <id>) [--options <json>] [-o <folder>] --json`

`--options` takes a JSON object; its keys override the same keys of the preset's options and every other key keeps
the preset's value (see "Editor tools" below). `--to` accepts format ids and aliases (`jpeg` is `jpg`). One entry per input, in input order. A combining preset lists
the same output for every input.

| key | type | notes |
| --- | --- | --- |
| `source` | string | absolute path of the input |
| `status` | string | `"succeeded"`, `"failed"` or `"cancelled"` |
| `outputs` | [string] | absolute paths of the published files; empty unless succeeded |
| `note` | string or null | `"fellBackToDownloads"` when the source folder was not writable and the output went to Downloads; `"replacedOriginal"` is reserved for the app's replace-original option, which the CLI never uses |
| `error` | string or null | human-readable message, set only when `status` is `"failed"` |

```json
{
  "results" : [
    {
      "error" : null,
      "note" : null,
      "outputs" : [
        "/Users/me/Pictures/photo.jpg"
      ],
      "source" : "/Users/me/Pictures/photo.png",
      "status" : "succeeded"
    },
    {
      "error" : "file not found",
      "note" : null,
      "outputs" : [

      ],
      "source" : "/Users/me/Pictures/gone.png",
      "status" : "failed"
    }
  ]
}
```

### `error` strings

`error` is the same text the human-readable output prints after the file name:

| text | meaning |
| --- | --- |
| `file not found` | the input is gone |
| `is a folder` | a folder that is not a document package |
| `not a regular file` | a FIFO, socket or device, which no engine is given |
| `unknown format .<ext>` | Pomelo doesn't know the file's format |
| `can't convert <from> to <to>` | no route between the two formats |
| `<engine>: <message>` | the engine failed on this file (a damaged or unsupported input); `<message>` is the engine's own, such as `exited with code 1: <the tool's last stderr lines>` |
| `<engine>: executable not found`, `<engine>: could not launch: <reason>`, `<engine>: engine not found` | the converter isn't available |
| the engine's sentence as written, such as `Needs macOS 26.`, `Apple Intelligence can't work with this document.`, `Download Italian for translation in System Settings, General, Language & Region.`, `It's password-protected`, `Pomelo can't read this RAR` or `It's too large to convert` | the route needs an engine this Mac can't run (`pomelo engines` lists it as `unsupported`), the on-device model refused or could not finish this file, Translation lacks the language pair, or the archive or spreadsheet engine refuses this file; all are failures, so a script sees them (P164) |
| `<engine>: timed out` | the converter stopped responding and was stopped |
| `<engine>: no conversion from <from> to <to>`, `<engine>: unresolved placeholder {<name>}`, `<engine>: produced no output`, `<engine>: returned <path>, outside its staging directory` | the converter misbehaved whatever the file |
| a sentence shown as the engine wrote it, such as `already compressed`, `No table found`, `No text found`, `No data found` or `It's already in Italian.` | the work does not apply to this file (never lowercased: a reason may start with a name) |
| `couldn't save: <reason>` | the output could not be published |

## `pomelo targets <file> --json`

Every format the file can become, sorted by `category`, then `format`.

| key | type | notes |
| --- | --- | --- |
| `source` | string | absolute path of the file |
| `targets[].format` | string | format id |
| `targets[].category` | string | `image`, `video`, `audio`, `pdf`, `document`, `text`, `archive`, `data`, `subtitle`, `font` or `other` |
| `targets[].hops` | int | number of conversion steps |
| `targets[].engines` | [string] | the engine of each step, in order |
| `targets[].flags` | [string] | any of `"lossy"`, `"layoutRisk"`, `"directOnly"`, in that order |

```json
{
  "source" : "/Users/me/Pictures/photo.png",
  "targets" : [
    {
      "category" : "image",
      "engines" : [
        "imageio"
      ],
      "flags" : [
        "lossy"
      ],
      "format" : "jpg",
      "hops" : 1
    }
  ]
}
```

## `pomelo engines --json`

Engines in registry order (built-in engines, then plugins). The human-readable output ends each line with the
state: `available <version>`, `missing — <install hint>` or `unsupported: <reason>`.

| key | type | notes |
| --- | --- | --- |
| `engines[].id` | string | |
| `engines[].name` | string | |
| `engines[].status` | string | `"available"`, `"missing"` or `"unsupported"` (this Mac can't run it, and installing nothing would change that) |
| `engines[].version` | string or null | set for an available engine that reports a version |
| `engines[].install` | string or null | install hint, set for a missing engine |
| `engines[].reason` | string or null | why this Mac can't run it, a sentence such as `Needs macOS 26.`, set for an unsupported engine |
| `pluginErrors` | [string] | absolute paths of plugin manifests that could not be loaded; empty when all loaded |

```json
{
  "engines" : [
    {
      "id" : "imageio",
      "install" : null,
      "name" : "ImageIO",
      "reason" : null,
      "status" : "available",
      "version" : null
    },
    {
      "id" : "pandoc",
      "install" : "brew install pandoc",
      "name" : "Pandoc",
      "reason" : null,
      "status" : "missing",
      "version" : null
    },
    {
      "id" : "translation",
      "install" : null,
      "name" : "Translation",
      "reason" : "Needs macOS 26.",
      "status" : "unsupported",
      "version" : null
    }
  ],
  "pluginErrors" : [

  ]
}
```

## `pomelo routes <from> <to> --json`

`from` and `to` are the resolved format ids (aliases are resolved). When there is no route, `cost` is `null`, `steps`
is empty and the exit code is `1`.

| key | type | notes |
| --- | --- | --- |
| `from`, `to` | string | |
| `cost` | int or null | the planner's score: the sum over the steps of (edge cost + 5 per hop [+ 100 for a `layoutRisk` edge]) |
| `steps[].from`, `steps[].to` | string | |
| `steps[].engine` | string | |

```json
{
  "cost" : 15,
  "from" : "png",
  "steps" : [
    {
      "engine" : "imageio",
      "from" : "png",
      "to" : "jpg"
    }
  ],
  "to" : "jpg"
}
```

Here the single ImageIO edge costs 10 and the hop adds 5. A two-step route such as `jpg` → `webp` (ImageIO to
`png`, then the `cwebp` plugin at its default cost of 30) scores (10 + 5) + (30 + 5) = 50.

## Usage errors

In `--json` mode a usage error (exit code `2`) prints this instead of the shapes above:

```json
{
  "error" : "Unknown format: zzz"
}
```

Messages: `Unknown format: <x>`, `Unknown preset: <x> (available: <ids>)`, `Pass --to <format> or --preset <id>`,
`Pass either --to or --preset, not both`, `No files given`, `Output folder not found: <path>`, `Not a folder: <path>`.

Every usage error exits `2`, including malformed command lines caught by the argument parser (an unknown flag, a
missing `targets` or `routes` argument, an unknown subcommand). Those are not JSON: their message goes to stderr
together with ArgumentParser's usage text. `--help` exits `0`.

## Editor tools

The editor presets (`trim`, `crop`, `split-video`, `compress-to-size`, `redact`, `organize-pages`, `resize`, `rotate`) take what the
app's editors decide through `--options`. A preset that needs input fails with exit code 2 unless `--options` holds an
`edit` or a `targetBytes`. Invalid JSON, a value that is not an object, an unknown edit kind or a `targetBytes` of 0
or less also exit with 2, as `invalid --options: <reason>`.

`edit` is an object with a `kind`:

| kind | shape | notes |
| --- | --- | --- |
| `trim` | `{"kind":"trim","start":2,"end":10}` | seconds |
| `split` | `{"kind":"split","points":[2,4]}` | seconds |
| `crop` | `{"kind":"crop","x":0,"y":0,"width":0.5,"height":0.5}` | a rectangle, below |
| `redact` | `{"kind":"redact","style":"fill","boxes":[{"x":0.1,"y":0.1,"width":0.2,"height":0.1}]}` | `style` is `"fill"` or `"pixelate"`; boxes are rectangles, below |
| `organize` | `{"kind":"organize","pages":[{"page":2,"rotation":0},{"page":0,"rotation":90}]}` | `page` is a 0-based index of the source, `rotation` 0, 90, 180 or 270 clockwise; the output's pages, in order |
| `resize` | `{"kind":"resize","mode":"width","width":1000}` | `mode` is `"scale"` (`percent`, 1 to 400), `"width"` or `"height"` (proportions kept) or `"exact"` (`width` and `height`: the picture fills the box, the overflow cut evenly, never stretched); sides run 1 to 16,384 px; the output is named `photo-1000x750.png` |
| `rotate` | `{"kind":"rotate","quarterTurns":1,"flipHorizontal":false}` | `quarterTurns` clockwise (any integer, taken modulo 4), then the optional horizontal flip; the output is `photo-rotated.png`; no turn and no flip is "Nothing to rotate" |

Rectangles are fractions from 0 to 1 with the origin at the top left, in the displayed orientation (a photo's EXIF
orientation or a video's rotation applied), so they land on what an editor would show.

`targetBytes` is the size "Compress to size" must not exceed, in bytes (decimal: 1 MB is 1,000,000). The output is
named after it (`photo-under-500kb.jpg`, `clip-under-1.5mb.mov`). A file it can't get under the size fails with
`can't get it under 500 KB` (or `it's already under …`, `it's too long to fit in …`); nothing is written.

```sh
pomelo convert clip.mov --preset trim --options '{"edit":{"kind":"trim","start":2,"end":6}}'
pomelo convert clip.mov --preset split-video --options '{"edit":{"kind":"split","points":[2,4]}}'
pomelo convert photo.jpg --preset crop --options '{"edit":{"kind":"crop","x":0,"y":0,"width":0.5,"height":0.5}}'
pomelo convert photo.jpg --preset compress-to-size --options '{"targetBytes":500000}'
pomelo convert photo.jpg --preset redact --options '{"edit":{"kind":"redact","style":"pixelate","boxes":[{"x":0.1,"y":0.1,"width":0.3,"height":0.1}]}}'
pomelo convert photo.jpg --preset resize --options '{"edit":{"kind":"resize","mode":"exact","width":1080,"height":1080}}'
pomelo convert photo.jpg --preset rotate --options '{"edit":{"kind":"rotate","quarterTurns":1}}'
pomelo convert doc.pdf --preset organize-pages --options '{"edit":{"kind":"organize","pages":[{"page":1,"rotation":0},{"page":0,"rotation":90}]}}'
```

Other option keys (`quality`, `scale`, ...) may be given in the same object and override the preset's own.

## Language and output format

Three more option keys, all unset by default:

| key | type | notes |
| --- | --- | --- |
| `language` | string | a BCP-47 identifier such as `it-IT`: the spoken language for the speech tools, the target language for Translate; unset means the system's language |
| `outputFormat` | string | with `--preset`, the tool's output among the formats it can make (a format id or alias); it becomes the target. A format the preset can't make is a usage error, `the <id> preset can't make <format> (it makes: <formats>)` |
| `aspect` | string | Smart crop's shape (`smart-crop`): `"1:1"`, `"4:5"`, `"4:3"` or `"16:9"`, the shape's ratio, applied landscape when the subject is wider than tall (so `4:5` gives 5:4 for a wide subject); unset fits the subject |

## On-device tools

Ten presets run on the Mac's own frameworks (Speech, Translation, Vision, Apple Intelligence). All but the last three
(`smart-crop`, `straighten` and `find-duplicates`, Vision requests every supported macOS has) need macOS 26 or later:
below it `pomelo engines` lists `speech`, `translation`, `documentscan` and `intelligence` as `unsupported`
with `Needs macOS 26.`, and a file sent to them fails with that reason. `intelligence` also reads `unsupported` on a Mac
whose model is not available (`Needs a Mac with Apple Intelligence.`, `Needs Apple Intelligence. Turn it on in System
Settings.` or `Apple Intelligence is still getting ready. Try again in a few minutes.`). Nothing leaves the Mac, and
recognized text is never written to a log or an error.

| preset | takes | makes | output name | `--options` |
| --- | --- | --- | --- | --- |
| `transcribe` | `mov`, `mp4`, `m4v`, `m4a`, `mp3`, `wav`, `aiff`, `caf`, `flac` | `txt`: what is said, a paragraph per stretch of speech | `<name>-transcript.txt` | `language`: the spoken language, unset means the system's |
| `make-subtitles` | the same | `srt` (or `vtt`): cues of at most two 42-character lines and 7 seconds | `<name>.srt`, next to the video as players expect | `language` as above; `outputFormat`: `srt` or `vtt` |
| `translate` | `srt`, `vtt`, `txt`, `md` | the same format | `<name>-<language>.<ext>`, such as `subs-it.srt` | `language`: the target, unset means the system's language |
| `scan-document` | an image or a `pdf` (its first 20 pages) | `md`: paragraphs, lists and tables in reading order, tables as pipe tables | `<name>.md` | |
| `extract-tables` | an image or a `pdf` (its first 20 pages) | `xlsx` (one sheet per table) or `csv` | `<name>-tables.xlsx`, `<name>-tables.csv`, or a folder `<name>-tables` of `<name>-1.csv`, `<name>-2.csv`… when there are several | `outputFormat`: `xlsx` or `csv` |
| `summarize` | `pdf`, `docx`, `doc`, `odt`, `rtf`, `html`, `txt`, `md` | `md`: a title and bullet points, in the document's own language | `<name>-summary.md` | |
| `extract-data` | an image or a `pdf` | `json` (or `csv`) holding what is printed: `kind`, `issuer`, `date` (ISO 8601), `total`, `currency`, `tax`, `lineItems` | `<name>-data.json` | `outputFormat`: `json` or `csv` |
| `smart-crop` | an image Crop takes (any it reads and writes but `pdf`, `ico`, `icns`) | the same format, cut to its subject plus a 6 % margin, upright; `No subject found` when Vision finds none | `<name>-cropped.<ext>` | `aspect`: the shape, above |
| `straighten` | the same | the same format: the photographed page flattened and cut to its edges, made exactly A-series or US Letter when within 4 % of it; `No document found`, `It's already flat` | `<name>-straightened.<ext>` | |
| `find-duplicates` | 2 to 500 images at once (`png`, `jpg`, `heic`, `tiff`, `avif`, `gif`, `bmp`), one job for all | `txt`: the groups of identical files and of look-alikes, the largest picture first; `No duplicates found` writes nothing | `<first>-duplicates.txt`, next to the first image | |

Transcribe and Make subtitles listen for one language: `language` (`en-US`, `it`), else the system's, matched to a
locale the recognizer has by its region (a bare `en` is the system's English, else American English). A language the
recognizer lacks fails with `Pomelo can't transcribe Klingon yet.`; one whose model is not on this Mac yet is
downloaded by the system first (that time is the first half of the progress), and a failed download fails with
`Pomelo couldn't download Italian for transcription. Try again when this Mac is online.` (both failures, exit code
`1`). A file without an audio track is `It has no sound`, one where nothing is said `No speech found`.

Translate detects the file's language and translates only between languages installed in System Settings (General,
Language & Region): a pair that is supported but not installed fails with `Download Italian for translation in
System Settings, General, Language & Region.`, a pair Translation lacks or a file whose language it can't tell fails
too (all three are failures, exit code `1`), and a file already in the target is `It's already in Italian.`. A
Markdown file's front matter (a leading `---` or `+++` block) stays as written.
Extract data leaves out any field the document does not print, and writes a date only when its order is certain.
Cells that start with `=`, `+`, `-` or `@` are written as text in `xlsx` and `csv`, so a spreadsheet never runs them.

```sh
pomelo convert interview.m4a --preset transcribe
pomelo convert clip.mp4 --preset make-subtitles --options '{"language":"it-IT","outputFormat":"vtt"}'
pomelo convert subs.srt --preset translate --options '{"language":"it"}'
pomelo convert scan.pdf --preset scan-document
pomelo convert table.png --preset extract-tables --options '{"outputFormat":"csv"}'
pomelo convert report.pdf --preset summarize
pomelo convert receipt.png --preset extract-data
pomelo convert portrait.jpg --preset smart-crop --options '{"aspect":"4:5"}'
pomelo convert page.jpg --preset straighten
pomelo convert a.jpg b.jpg c.heic --preset find-duplicates
```

These are tools, not conversions: `pomelo targets` and `pomelo routes` list conversions only, so they run through
`pomelo convert --preset`, and `pomelo engines` shows whether each engine (`speech`, `translation`, `documentscan`,
`intelligence`) can run on this Mac.
