import Foundation
import Testing
@testable import PomeloCore

@Suite struct MarkdownSegmentsTests {
    private typealias Segment = MarkdownSegments.Segment

    private func translated(_ text: String) -> [String] {
        MarkdownSegments.split(text).compactMap { if case let .translate(value) = $0 { value } else { nil } }
    }

    private func kept(_ text: String) -> String {
        MarkdownSegments.split(text).compactMap { if case let .keep(value) = $0 { value } else { nil } }.joined()
    }

    private func roundTrips(_ text: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(MarkdownSegments.join(MarkdownSegments.split(text)) == text, sourceLocation: sourceLocation)
    }

    private let fixtures: [String] = [
        "",
        "\n",
        "\n\n\n",
        "Hello world",
        "Hello world\n",
        "# Title\n\nSome *emphasis* and **strong** text.\n",
        "Title\n=====\n\nSub\n---\n\ntext\n",
        "***\n\n- - -\n\n___\n",
        "- one\n- two\n  - nested [link](http://a.b/c_d) text\n\n1. first\n2) second\n- [ ] todo\n- [x] done\n",
        "> quote one\n> > nested quote\n>\n> back\n",
        "```swift\nlet x = \"translate me\"\n```\nafter\n",
        "~~~\nplain tilde fence\n~~~\n",
        "````\n```\ninner\n```\n````\n",
        "```\nunclosed fence runs to the end",
        "text\n\n    indented code line\n    another\n\nback to text\n",
        "Use `ls -la` and ``code with ` tick`` here.\n",
        "An autolink <https://example.com/a?b=c&d=e> and <me@example.com> and https://bare.example.org/x.\n",
        "![alt text](img/a.png \"Title (x)\") and [ref link][id] and [collapsed][] and [^1].\n\n[id]: http://example.com \"Ref\"\n[^1]: A footnote.\n",
        "Inline <b>HTML</b> and <br/> and <!-- a comment --> done.\n",
        "<!--\nmulti-line\ncomment\n-->\nvisible text\n",
        "| Name | Age |\n| :--- | ---: |\n| Ann | 30 |\n| Bob \\| Co | 25 |\n",
        "a | b\n--|--\n1 | 2\n",
        "Windows line endings\r\nsecond line\r\n\r\n# Head\r\n",
        "No trailing newline at the end",
        "Ünïcödé 日本語 émoji 🎉 text\n\n- 🍊 item\n",
        "Hard wrapped paragraph that\ncontinues here and\nends here.\n\nNext paragraph.\n",
        "## Closing hashes ##\n###### Six\n####### seven is text\n#nospace\n",
        "---\ntitle: Front\n---\n\nBody\n",
        "+++\r\ntitle = \"Front\"\r\n+++\r\nBody",
        "---\nnever closed\n",
    ]

    @Test func joiningTheSplitGivesTheTextBackForEveryFixture() {
        for fixture in fixtures { roundTrips(fixture) }
    }

    @Test func joiningTheSplitGivesTheTextBackForRandomMarkdownLikeText() {
        let alphabet = Array("`[]()<>|\n\r #-*~\\!1.:ab_>=\t").map(String.init)
        var seed: UInt64 = 0x5EED
        for _ in 0..<2000 {
            var text = ""
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let length = Int((seed >> 33) % 40)
            for _ in 0..<length {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                text += alphabet[Int((seed >> 33) % UInt64(alphabet.count))]
            }
            roundTrips(text)
        }
    }

    /// Front matter is the page's data: a site build reads its keys, so none of it goes to the translator.
    @Test func yamlFrontMatterIsKeptWhole() {
        let yaml = "---\nlayout: post\ntitle: \"Walking in the mountains\"\ndate: 2026-10-01\ntags: [travel, hiking]\n---\n"
        #expect(MarkdownSegments.split(yaml + "\nHello world\n")
            == [.keep(yaml + "\n"), .translate("Hello world"), .keep("\n")])
        let dots = "---\r\ntitle: A walk\r\n...\r\n"
        #expect(MarkdownSegments.split(dots + "# Heading\r\n") == [.keep(dots + "# "), .translate("Heading"), .keep("\r\n")])
        #expect(translated("\u{FEFF}--- \ntitle: A walk\n---  \nBody text\n") == ["Body text"])
    }

    @Test func tomlFrontMatterIsKeptWhole() {
        let toml = "+++\ntitle = \"Walking in the mountains\"\ndraft = false\n+++\n"
        #expect(MarkdownSegments.split(toml + "Hello world\n") == [.keep(toml), .translate("Hello world"), .keep("\n")])
        // A TOML block closes only on `+++`.
        #expect(translated("+++\ntitle = \"A walk\"\n---\nBody\n").contains { $0.contains("A walk") })
    }

    /// Pandoc's rule: the line after the opening `---` must not be blank, or the file opens with a horizontal rule.
    @Test func aLeadingRuleFollowedByABlankLineIsNotFrontMatter() {
        #expect(translated("---\n\nIntro paragraph.\n\n---\n\n# Title\n") == ["Intro paragraph.", "Title"])
        #expect(translated("---\r\n  \r\nIntro paragraph.\r\n---\r\n") == ["Intro paragraph."])
        // Front matter whose first key follows at once, and an empty block, are still the page's data.
        #expect(translated("---\ntitle: A walk\n---\n\nBody text\n") == ["Body text"])
        #expect(translated("---\n---\nBody text\n") == ["Body text"])
        // A blank line after `+++` stays TOML front matter.
        #expect(translated("+++\n\ntitle = \"A walk\"\n+++\nBody text\n") == ["Body text"])
    }

    /// Only a block that opens the file and closes is front matter: a rule later on, or one never closed, is Markdown.
    @Test func aRuleThatIsNotFrontMatterIsStillMarkdown() {
        #expect(translated("Intro text\n---\ntitle: a key\n---\n") == ["Intro text", "title: a key"])
        #expect(translated("---\ntitle: never closed\n") == ["title: never closed"])
        #expect(translated("  ---\ntitle: indented\n---\n") == ["title: indented"])
    }

    @Test func plainTextIsTranslatedAndItsLineEndKept() {
        #expect(MarkdownSegments.split("Hello world\n") == [.translate("Hello world"), .keep("\n")])
        #expect(MarkdownSegments.split("") == [])
    }

    @Test func headingListAndQuoteMarkersAreKept() {
        #expect(MarkdownSegments.split("## Title\n") == [.keep("## "), .translate("Title"), .keep("\n")])
        #expect(MarkdownSegments.split("- item\n") == [.keep("- "), .translate("item"), .keep("\n")])
        #expect(MarkdownSegments.split("  3. third\n") == [.keep("  3. "), .translate("third"), .keep("\n")])
        #expect(MarkdownSegments.split("- [x] done\n") == [.keep("- [x] "), .translate("done"), .keep("\n")])
        #expect(MarkdownSegments.split("> > quoted\n") == [.keep("> > "), .translate("quoted"), .keep("\n")])
        #expect(MarkdownSegments.split("## Closing ##\n") == [.keep("## "), .translate("Closing"), .keep(" ##\n")])
        #expect(translated("####### seven\n#nospace\n") == ["####### seven\n#nospace"])
    }

    @Test func fencedBlocksAreKeptWhole() {
        #expect(translated("```swift\nlet x = \"translate me\"\n```\nafter\n") == ["after"])
        #expect(translated("~~~\ninside tilde\n~~~\nafter\n") == ["after"])
        #expect(translated("````\n```\ninner text\n```\nstill inside\n````\nafter\n") == ["after"])
        #expect(translated("```\nunclosed text\nmore text") == [])
        #expect(translated("- item\n\n  ```\n  code in list\n  ```\n") == ["item"])
    }

    @Test func indentedCodeIsKeptButIndentedListContinuationsAreNot() {
        #expect(translated("text\n\n    code line\n    more code\n\nback\n") == ["text", "back"])
        #expect(translated("- item\n\n    continued paragraph\n") == ["item", "continued paragraph"])
    }

    @Test func inlineCodeIsKept() {
        #expect(MarkdownSegments.split("Run `ls -la` now\n") == [.translate("Run"), .keep(" `ls -la` "), .translate("now"), .keep("\n")])
        #expect(translated("Use ``a ` b`` here\n") == ["Use", "here"])
        #expect(translated("Unclosed ` tick stays text\n") == ["Unclosed ` tick stays text"])
    }

    @Test func autolinksAndBareURLsAreKept() {
        #expect(translated("See <https://example.com/a?b=c> now\n") == ["See", "now"])
        #expect(translated("Mail <me@example.com> please\n") == ["Mail", "please"])
        #expect(translated("Go to https://example.com/x_y, then stop\n") == ["Go to", ", then stop"])
    }

    @Test func aLinkKeepsItsURLAndTranslatesItsText() {
        let segments = MarkdownSegments.split("See [the docs](https://example.com/a_b) for more\n")
        #expect(segments == [
            .translate("See"), .keep(" ["), .translate("the docs"), .keep("](https://example.com/a_b) "),
            .translate("for more"), .keep("\n"),
        ])
        #expect(translated("![alt text](img/a.png \"Title\")\n") == ["alt text"])
        #expect(kept("![alt text](img/a.png \"Title\")\n").contains("img/a.png \"Title\""))
        #expect(translated("[a link](http://x.y/(paren)) tail\n") == ["a link", "tail"])
        #expect(translated("A [ref link][id] and [^1] done\n") == ["A", "ref link", "and", "done"])
    }

    @Test func linkReferenceDefinitionsAreKept() {
        #expect(translated("[id]: http://example.com \"Title\"\ntext\n") == ["text"])
    }

    @Test func htmlTagsAndCommentsAreKept() {
        #expect(MarkdownSegments.split("<b>bold</b> text\n") == [.keep("<b>"), .translate("bold"), .keep("</b> "), .translate("text"), .keep("\n")])
        #expect(translated("a <!-- note --> b\n") == ["a", "b"])
        #expect(translated("<!--\nhidden words\n-->\nvisible words\n") == ["visible words"])
        #expect(translated("<div class=\"x y\">\nbody text\n</div>\n") == ["body text"])
    }

    @Test func tableCellsAreTranslatedOneByOneAndThePipesKept() {
        let table = "| Name | Age |\n| :--- | ---: |\n| Ann | 30 |\n| Bob \\| Co | 25 |\n"
        #expect(translated(table) == ["Name", "Age", "Ann", "Bob \\| Co"])
        #expect(kept(table).contains("| :--- | ---: |"))
        #expect(translated("a | b\n--|--\nc | d\n") == ["a", "b", "c", "d"])
        #expect(translated("| `code` | text |\n| - | - |\n") == ["text"])
    }

    @Test func aPipeInProseIsNotATable() {
        #expect(translated("either this | or that\n") == ["either this | or that"])
    }

    @Test func thematicBreaksAndSetextUnderlinesAreKept() {
        #expect(translated("Title\n=====\n\nSub\n---\n\n***\n- - -\n") == ["Title", "Sub"])
    }

    @Test func linesOfOneParagraphAreTranslatedTogether() {
        #expect(MarkdownSegments.split("first line\nsecond line\n") == [.translate("first line\nsecond line"), .keep("\n")])
        #expect(translated("# Head\ntext below\n") == ["Head", "text below"])
        #expect(translated("one\n\ntwo\n") == ["one", "two"])
        #expect(translated("windows\r\nlines\r\n") == ["windows\r\nlines"])
    }

    @Test func textWithoutLettersIsNotSentToTheTranslator() {
        #expect(translated("2026\n") == [])
        #expect(translated("- 1.5 %\n") == [])
        #expect(translated("日本語\n") == ["日本語"])
    }

    @Test func spacesAroundATranslatableSpanStayOutsideIt() {
        #expect(MarkdownSegments.split("  indented text  \n") == [.keep("  "), .translate("indented text"), .keep("  \n")])
    }
}
