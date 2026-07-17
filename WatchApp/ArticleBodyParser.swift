//
//  ArticleBodyParser.swift
//  NetNewsWire Watch App
//
//  Copyright © 2026 Ranchero Software. All rights reserved.
//

import Foundation

// M3 — see Technotes/WatchApp.md "Reading experience > Article view". Supersedes
// ArticleBodyPlainTextConverter (M1 scaffolding in ArticleView.swift) with a block-based
// parser: paragraphs, headings, blockquotes, lists, code blocks, image placeholders, and a
// plain-text fallback for tables. Inline styling (bold/italic/code/links) is preserved as
// AttributedString attributes within each block.

/// One block of parsed article content, in reading order.
struct BodyBlock: Identifiable, Equatable, Sendable {

	enum Kind: Equatable, Sendable {
		case paragraph(AttributedString)
		case heading(level: Int, AttributedString)
		case blockquote(AttributedString)
		case list(items: [AttributedString], ordered: Bool)
		case code(String)
		case image(altText: String)
	}

	let id: Int
	let kind: Kind
}

/// Parses feed-provided article HTML into an array of `BodyBlock`s for native SwiftUI
/// rendering. A single hand-rolled, tag-aware pass over the string — no `NSAttributedString(html:)`
/// (WebKit-backed, unavailable here) and no external dependencies. Malformed HTML degrades
/// gracefully — unclosed tags, stray angle brackets, and unknown elements never crash the parse.
enum ArticleBodyParser {

	/// Parse HTML synchronously into blocks. Pure function, safe to call from any context.
	static func blocks(fromHTML html: String) -> [BodyBlock] {
		var parser = HTMLBlockParser()
		return parser.parse(html)
	}

	/// Load and parse an article's stored content file off the main actor. Returns `nil` if
	/// the file can't be read or decoded as UTF-8 text.
	static func blocks(contentsOf url: URL) async -> [BodyBlock]? {
		await Task.detached(priority: .userInitiated) {
			guard let data = try? Data(contentsOf: url), let html = String(data: data, encoding: .utf8) else {
				return nil
			}
			return blocks(fromHTML: html)
		}.value
	}
}

// MARK: - HTMLBlockParser

/// Stateful single-pass tokenizer that turns an HTML string into `[BodyBlock]`. Not
/// `Sendable` itself (it doesn't need to be — it's created, driven, and discarded within one
/// synchronous call), but everything it produces (`BodyBlock`) is.
private struct HTMLBlockParser {

	private enum Mode {
		case normal
		case pre
	}

	/// Which kind of block is currently accumulating text in `currentText`. Block-level tags
	/// (p/div/h1-6/blockquote/li/td/th) switch this; inline tags (b/i/a/code) don't.
	private enum BlockContext {
		case none
		case paragraph
		case heading(Int)
		case blockquote
		case listItem
		case tableCell
	}

	private struct InlineStyle {
		var boldCount = 0
		var italicCount = 0
		var codeCount = 0
		var linkHref: String?
	}

	private var blocks: [BodyBlock] = []
	private var nextID = 0

	private var mode: Mode = .normal
	private var blockContext: BlockContext = .none

	/// Open `<blockquote>` nesting level. While inside a quote, paragraph boundaries produce
	/// `.blockquote` blocks rather than `.paragraph` — `<blockquote><p>…</p></blockquote>` is
	/// the common form and must keep its quote styling.
	private var blockquoteDepth = 0

	/// Text already flushed into the current block, with attributes applied per run.
	private var currentText = AttributedString()
	/// Pending plain characters that share the current inline style — flushed into
	/// `currentText` whenever the style changes or the block ends, so we only build one
	/// AttributedString run per style span rather than one per character.
	private var textBuffer = ""
	/// Tracks whether the last character appended to `textBuffer` was a (collapsed) space,
	/// so runs of literal HTML whitespace collapse to a single space. Reset at block
	/// boundaries so leading whitespace of a new block is dropped.
	private var lastAppendedWasSpace = true

	private var style = InlineStyle()

	/// One entry per open <ul>/<ol>. Closing a list flattens its items into the parent list
	/// (if nested) or emits a `.list` block (if outermost) — nested lists are intentionally
	/// flattened per the design's plain-text-table-style simplification for v1.
	private var listStack: [(ordered: Bool, items: [AttributedString])] = []

	private var tableDepth = 0
	/// Plain-text cells accumulated for the row currently being scanned; joined into one
	/// paragraph block per row on </tr>, per the design's plain-text table fallback.
	private var rowCells: [String] = []

	/// Raw (whitespace-preserving, tag-stripped, entity-decoded) contents of the <pre> block
	/// currently being scanned.
	private var codeBuffer = ""

	mutating func parse(_ rawHTML: String) -> [BodyBlock] {
		let html = Self.removingNonContentSections(from: rawHTML)
		var index = html.startIndex

		while index < html.endIndex {
			let character = html[index]

			if mode == .pre {
				if character == "<", Self.startsTag(in: html, afterAngleBracketAt: index) {
					index = html.index(after: index)
					consumeTagInPreMode(html: html, index: &index)
				} else if character == "&" {
					codeBuffer += Self.consumeEntity(in: html, index: &index)
				} else {
					codeBuffer.append(character)
					index = html.index(after: index)
				}
				continue
			}

			if character == "<", Self.startsTag(in: html, afterAngleBracketAt: index) {
				index = html.index(after: index)
				consumeTag(html: html, index: &index)
			} else if character == "&" {
				let decoded = Self.consumeEntity(in: html, index: &index)
				appendText(decoded, collapsible: false)
			} else {
				appendText(String(character), collapsible: true)
				index = html.index(after: index)
			}
		}

		// End-of-document cleanup: flush whatever block, row, or list levels were still open
		// (malformed HTML missing closing tags shouldn't lose content) and a dangling <pre>.
		finalizeCurrentBlock()
		flushRow()
		while !listStack.isEmpty {
			popList()
		}
		if mode == .pre {
			appendBlock(.code(codeBuffer))
			codeBuffer = ""
		}

		return blocks
	}

	// MARK: Text accumulation

	private mutating func appendText(_ text: String, collapsible: Bool) {
		ensureBlockContext()
		for character in text {
			if collapsible, character.isWhitespace {
				if !lastAppendedWasSpace {
					textBuffer.append(" ")
					lastAppendedWasSpace = true
				}
			} else {
				textBuffer.append(character)
				lastAppendedWasSpace = false
			}
		}
	}

	/// Text with no enclosing block tag (a bare run of text or inline tags at the top level,
	/// or directly inside a list/table container) implicitly starts a paragraph — or another
	/// blockquote paragraph when we're inside an open `<blockquote>`.
	private mutating func ensureBlockContext() {
		if case .none = blockContext {
			blockContext = blockquoteDepth > 0 ? .blockquote : .paragraph
		}
	}

	private mutating func flushTextBuffer() {
		guard !textBuffer.isEmpty else {
			return
		}
		currentText.append(AttributedString(textBuffer, attributes: currentContainer()))
		textBuffer = ""
	}

	private func currentContainer() -> AttributeContainer {
		var container = AttributeContainer()

		var intent: InlinePresentationIntent = []
		if style.boldCount > 0 {
			intent.insert(.stronglyEmphasized)
		}
		if style.italicCount > 0 {
			intent.insert(.emphasized)
		}
		if style.codeCount > 0 {
			intent.insert(.code)
		}
		if !intent.isEmpty {
			container.inlinePresentationIntent = intent
		}

		// Absolute http/https links only — relative URLs and other schemes (mailto:, etc.)
		// have nowhere useful to go from a watch, so they render as plain text.
		if let href = style.linkHref, let url = URL(string: href), let scheme = url.scheme?.lowercased(),
			scheme == "http" || scheme == "https" {
			container.link = url
		}

		return container
	}

	private mutating func trimTrailingSpace() {
		if let last = currentText.characters.last, last == " " {
			currentText.characters.removeLast()
		}
	}

	// MARK: Block finalization

	private mutating func appendBlock(_ kind: BodyBlock.Kind) {
		blocks.append(BodyBlock(id: nextID, kind: kind))
		nextID += 1
	}

	/// Closes out whatever block is currently accumulating: emits it (paragraph/heading/
	/// blockquote), files it into the enclosing list item or table row, or drops it if empty.
	/// Called on every block-level boundary, so it also doubles as "start a fresh block".
	private mutating func finalizeCurrentBlock() {
		flushTextBuffer()
		trimTrailingSpace()

		switch blockContext {
		case .none:
			break
		case .paragraph:
			if !currentText.characters.isEmpty {
				appendBlock(.paragraph(currentText))
			}
		case .heading(let level):
			if !currentText.characters.isEmpty {
				appendBlock(.heading(level: level, currentText))
			}
		case .blockquote:
			if !currentText.characters.isEmpty {
				appendBlock(.blockquote(currentText))
			}
		case .listItem:
			if !currentText.characters.isEmpty, !listStack.isEmpty {
				let lastIndex = listStack.count - 1
				listStack[lastIndex].items.append(currentText)
			}
		case .tableCell:
			let trimmed = String(currentText.characters).trimmingCharacters(in: .whitespacesAndNewlines)
			if !trimmed.isEmpty {
				rowCells.append(trimmed)
			}
		}

		currentText = AttributedString()
		textBuffer = ""
		lastAppendedWasSpace = true
		blockContext = .none
	}

	private mutating func popList() {
		guard let finished = listStack.popLast() else {
			return
		}
		guard !finished.items.isEmpty else {
			return
		}
		if listStack.isEmpty {
			appendBlock(.list(items: finished.items, ordered: finished.ordered))
		} else {
			// Nested list — flatten its items into the parent rather than modeling nesting.
			let lastIndex = listStack.count - 1
			listStack[lastIndex].items.append(contentsOf: finished.items)
		}
	}

	private mutating func flushRow() {
		guard !rowCells.isEmpty else {
			return
		}
		let rowText = rowCells.joined(separator: " ")
		rowCells = []
		guard !rowText.isEmpty else {
			return
		}
		appendBlock(.paragraph(AttributedString(rowText)))
	}

	// MARK: Tag handling

	private mutating func consumeTag(html: String, index: inout String.Index) {
		var raw = ""
		while index < html.endIndex, html[index] != ">" {
			raw.append(html[index])
			index = html.index(after: index)
		}
		if index < html.endIndex {
			index = html.index(after: index)
		}
		guard let parsed = Self.parseTag(raw) else {
			return
		}
		dispatch(name: parsed.name, isClosing: parsed.isClosing, attrsRaw: parsed.attrsRaw)
	}

	/// Inside <pre>, every other tag (typically <code> or syntax-highlighting <span>s) is
	/// swallowed silently — only the matching </pre> ends the block.
	private mutating func consumeTagInPreMode(html: String, index: inout String.Index) {
		var raw = ""
		while index < html.endIndex, html[index] != ">" {
			raw.append(html[index])
			index = html.index(after: index)
		}
		if index < html.endIndex {
			index = html.index(after: index)
		}
		guard let parsed = Self.parseTag(raw), parsed.isClosing, parsed.name == "pre" else {
			return
		}
		appendBlock(.code(codeBuffer))
		codeBuffer = ""
		mode = .normal
	}

	private mutating func dispatch(name: String, isClosing: Bool, attrsRaw: Substring) {
		switch name {
		case "br":
			if !isClosing {
				ensureBlockContext()
				flushTextBuffer()
				currentText.append(AttributedString("\n"))
				lastAppendedWasSpace = true
			}

		case "p", "div", "section", "article":
			switch blockContext {
			case .listItem, .tableCell:
				// Inside a list item or table cell, paragraph tags act as soft line breaks —
				// markdown renderers wrap "loose" list items in <p>, and finalizing here would
				// scatter those items into stray paragraph blocks.
				flushTextBuffer()
				if !isClosing, !currentText.characters.isEmpty {
					currentText.append(AttributedString("\n"))
					lastAppendedWasSpace = true
				}
			default:
				finalizeCurrentBlock()
			}

		case "h1", "h2", "h3", "h4", "h5", "h6":
			finalizeCurrentBlock()
			if !isClosing, let level = Int(name.dropFirst()) {
				blockContext = .heading(min(max(level, 1), 6))
			}

		case "blockquote":
			finalizeCurrentBlock()
			if isClosing {
				blockquoteDepth = max(0, blockquoteDepth - 1)
			} else {
				blockquoteDepth += 1
				blockContext = .blockquote
			}

		case "ul", "ol":
			finalizeCurrentBlock()
			if isClosing {
				popList()
			} else {
				listStack.append((ordered: name == "ol", items: []))
			}

		case "li":
			finalizeCurrentBlock()
			if !isClosing {
				blockContext = .listItem
			}

		case "pre":
			if !isClosing {
				finalizeCurrentBlock()
				mode = .pre
				codeBuffer = ""
			}

		case "code":
			// Only reached outside <pre> (pre-mode tags go through consumeTagInPreMode) —
			// this is inline `<code>`, styled via InlinePresentationIntent.code.
			flushTextBuffer()
			if isClosing {
				style.codeCount = max(0, style.codeCount - 1)
			} else {
				style.codeCount += 1
			}

		case "b", "strong":
			flushTextBuffer()
			if isClosing {
				style.boldCount = max(0, style.boldCount - 1)
			} else {
				style.boldCount += 1
			}

		case "i", "em":
			flushTextBuffer()
			if isClosing {
				style.italicCount = max(0, style.italicCount - 1)
			} else {
				style.italicCount += 1
			}

		case "a":
			flushTextBuffer()
			if isClosing {
				style.linkHref = nil
			} else if let href = Self.extractAttribute("href", from: attrsRaw) {
				style.linkHref = Self.decodingEntities(in: href)
			}

		case "img":
			let altText = Self.decodingEntities(in: Self.extractAttribute("alt", from: attrsRaw) ?? "")
			// Images are their own block, but feed content often puts one mid-paragraph —
			// resume the surrounding context afterward so trailing text isn't orphaned.
			let resumeContext = blockContext
			finalizeCurrentBlock()
			appendBlock(.image(altText: altText))
			blockContext = resumeContext

		case "table":
			if isClosing {
				flushRow()
				tableDepth = max(0, tableDepth - 1)
			} else {
				finalizeCurrentBlock()
				tableDepth += 1
			}

		case "tr":
			if isClosing {
				flushRow()
			} else {
				rowCells = []
			}

		case "td", "th":
			finalizeCurrentBlock()
			if !isClosing {
				blockContext = .tableCell
			}

		default:
			// Unrecognized tag: dropped, but its inner text still flows through untouched.
			break
		}
	}

	// MARK: - Static helpers

	/// HTML's tokenizer treats `<` as markup only when followed by a letter, `/`, `!`, or
	/// `?` — anything else (as in `1 < 2`, common inside code blocks and prose) is literal
	/// text, and consuming it as a tag would swallow everything to the next `>`.
	private static func startsTag(in html: String, afterAngleBracketAt index: String.Index) -> Bool {
		let next = html.index(after: index)
		guard next < html.endIndex else {
			return false
		}
		let character = html[next]
		return character.isLetter || character == "/" || character == "!" || character == "?"
	}

	/// Strips <script>, <style>, and <head> (with their full contents) plus HTML comments
	/// before tokenizing. This is the one place a regex full-document pass is used rather
	/// than the tag-aware tokenizer: script/style bodies can contain stray `<`/`>` that
	/// aren't markup (e.g. `if (a < b)`), which would desync a tag-by-tag scan. A non-greedy
	/// regex matches the whole span atomically instead.
	private static func removingNonContentSections(from html: String) -> String {
		var result = html
		for tag in ["script", "style", "head"] {
			let pattern = "(?is)<\(tag)\\b[^>]*>.*?</\(tag)>"
			result = result.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
		}
		result = result.replacingOccurrences(of: "(?s)<!--.*?-->", with: "", options: .regularExpression)
		return result
	}

	/// Parses raw tag content (the text between `<` and `>`, exclusive) into a name,
	/// closing/opening flag, and the remaining attributes substring. Returns `nil` for empty,
	/// comment (`!--`), or processing-instruction (`?`) content it doesn't handle — those are
	/// already stripped by `removingNonContentSections` in the normal case, but malformed
	/// input degrades to "ignore this tag" rather than crashing.
	private static func parseTag(_ raw: String) -> (name: String, isClosing: Bool, attrsRaw: Substring)? {
		var content = Substring(raw).drop(while: { $0.isWhitespace })
		guard !content.isEmpty else {
			return nil
		}
		guard !content.hasPrefix("!"), !content.hasPrefix("?") else {
			return nil
		}

		let isClosing = content.hasPrefix("/")
		if isClosing {
			content = content.dropFirst().drop(while: { $0.isWhitespace })
		}

		var nameEnd = content.startIndex
		while nameEnd < content.endIndex, !content[nameEnd].isWhitespace, content[nameEnd] != "/" {
			nameEnd = content.index(after: nameEnd)
		}
		let name = content[content.startIndex..<nameEnd].lowercased()
		guard !name.isEmpty else {
			return nil
		}

		return (name, isClosing, content[nameEnd...])
	}

	/// Finds `name="value"` (or `'value'`, or a bare unquoted value) within a tag's attribute
	/// text. Case-insensitive; requires the match to be preceded by a word boundary so it
	/// doesn't fire on `data-href` when looking for `href`.
	private static func extractAttribute(_ name: String, from raw: Substring) -> String? {
		var searchRange = raw.startIndex..<raw.endIndex

		while let matchRange = raw.range(of: name, options: .caseInsensitive, range: searchRange) {
			let precededByBoundary = matchRange.lowerBound == raw.startIndex
				|| raw[raw.index(before: matchRange.lowerBound)].isWhitespace

			var cursor = matchRange.upperBound
			while cursor < raw.endIndex, raw[cursor].isWhitespace {
				cursor = raw.index(after: cursor)
			}

			if precededByBoundary, cursor < raw.endIndex, raw[cursor] == "=" {
				cursor = raw.index(after: cursor)
				while cursor < raw.endIndex, raw[cursor].isWhitespace {
					cursor = raw.index(after: cursor)
				}
				guard cursor < raw.endIndex else {
					return nil
				}

				let quote = raw[cursor]
				if quote == "\"" || quote == "'" {
					let valueStart = raw.index(after: cursor)
					guard let quoteEnd = raw[valueStart...].firstIndex(of: quote) else {
						return String(raw[valueStart...])
					}
					return String(raw[valueStart..<quoteEnd])
				} else {
					var valueEnd = cursor
					while valueEnd < raw.endIndex, !raw[valueEnd].isWhitespace {
						valueEnd = raw.index(after: valueEnd)
					}
					return String(raw[cursor..<valueEnd])
				}
			}

			searchRange = matchRange.upperBound..<raw.endIndex
		}

		return nil
	}

	// MARK: - Entities
	// Copied from ArticleBodyPlainTextConverter (WatchApp/ArticleView.swift), which this file
	// supersedes; restructured to decode one entity at a time from a tokenizer index rather
	// than transforming a whole string.

	private static let namedEntities: [Substring: Character] = [
		"amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
		"nbsp": "\u{00A0}", "mdash": "\u{2014}", "ndash": "\u{2013}",
		"hellip": "\u{2026}", "lsquo": "\u{2018}", "rsquo": "\u{2019}",
		"ldquo": "\u{201C}", "rdquo": "\u{201D}", "copy": "\u{00A9}"
	]

	/// Decodes every entity in a standalone string. Used for attribute values (`href`, `alt`)
	/// which are extracted from raw tag text before the main tokenizer's char-by-char entity
	/// handling ever sees them — a URL's `&amp;` needs decoding same as body text does.
	private static func decodingEntities(in string: String) -> String {
		guard string.contains("&") else {
			return string
		}
		var result = ""
		result.reserveCapacity(string.count)
		var index = string.startIndex
		while index < string.endIndex {
			if string[index] == "&" {
				result += consumeEntity(in: string, index: &index)
			} else {
				result.append(string[index])
				index = string.index(after: index)
			}
		}
		return result
	}

	/// The longest recognized entity is a numeric form like `&#xFFFFF;` — anything without a
	/// semicolon within a short window is a bare ampersand, not an entity.
	private static let maxEntityLength = 10

	/// `index` points at `&` on entry. Advances `index` past the consumed span and returns
	/// the decoded character (named or numeric entity), or the original text unchanged if it
	/// isn't a recognized entity. The semicolon search is bounded and stops at whitespace or
	/// markup characters: a bare `&` (as in "Fish & Chips") must consume only itself, or the
	/// unbounded scan to the document's next `;` would swallow legitimate text and tags.
	private static func consumeEntity(in html: String, index: inout String.Index) -> String {
		let ampersandIndex = index

		guard let semicolonIndex = boundedSemicolonIndex(in: html, after: ampersandIndex) else {
			index = html.index(after: ampersandIndex)
			return "&"
		}

		let entityStart = html.index(after: ampersandIndex)
		let entity = html[entityStart..<semicolonIndex]
		index = html.index(after: semicolonIndex)

		if let scalar = numericScalar(for: entity) {
			return String(Character(scalar))
		}
		if let named = namedEntities[entity] {
			return String(named)
		}
		return String(html[ampersandIndex...semicolonIndex])
	}

	private static func boundedSemicolonIndex(in html: String, after ampersandIndex: String.Index) -> String.Index? {
		var cursor = html.index(after: ampersandIndex)
		var scanned = 0
		while cursor < html.endIndex, scanned < maxEntityLength {
			let character = html[cursor]
			if character == ";" {
				return cursor
			}
			if character.isWhitespace || character == "<" || character == ">" || character == "&" {
				return nil
			}
			cursor = html.index(after: cursor)
			scanned += 1
		}
		return nil
	}

	private static func numericScalar(for entity: Substring) -> Unicode.Scalar? {
		if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
			guard let value = UInt32(entity.dropFirst(2), radix: 16) else {
				return nil
			}
			return Unicode.Scalar(value)
		}
		if entity.hasPrefix("#") {
			guard let value = UInt32(entity.dropFirst()) else {
				return nil
			}
			return Unicode.Scalar(value)
		}
		return nil
	}
}
