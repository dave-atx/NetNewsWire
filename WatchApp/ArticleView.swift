//
//  ArticleView.swift
//  NetNewsWire Watch App
//
//  Copyright © 2026 Ranchero Software. All rights reserved.
//

import SwiftUI

// M1 scaffolding — see Technotes/WatchApp.md "Reading experience > Article view". M1 renders
// a plain-text body; the block-based renderer (paragraphs, headings, links, etc.) is M3.

/// Article reading view. Loads its content file on demand from the store and strips it to
/// plain text off the main actor; header/footer read only the metadata already in memory.
struct ArticleView: View {

	let articleID: String
	var store: WatchStore

	@State private var bodyText: String?
	@State private var isLoadingBody = true

	@Environment(\.isLuminanceReduced) private var isLuminanceReduced

	private var article: WatchArticleRecord? {
		store.article(for: articleID)
	}

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 8) {
				if let article {
					header(for: article)
					Divider()
					content(for: article)
					Divider()
					footer(for: article)
				} else {
					Text("This article is no longer available.")
						.foregroundStyle(.secondary)
				}
			}
			.padding(.horizontal, 2)
		}
		.navigationTitle(article?.feedName ?? "Article")
		.task(id: articleID) {
			await loadBody()
		}
		.onAppear {
			store.setOpenArticle(articleID)
		}
		.onDisappear {
			store.setOpenArticle(nil)
		}
	}

	@ViewBuilder
	private func header(for article: WatchArticleRecord) -> some View {
		VStack(alignment: .leading, spacing: 4) {
			Text(article.title)
				.font(.headline)
			HStack(spacing: 4) {
				Text(article.feedName)
				if let datePublished = article.datePublished {
					Text("·")
					Text(datePublished, format: .dateTime.month(.abbreviated).day())
				}
			}
			.font(.caption2)
			.foregroundStyle(.secondary)
		}
	}

	@ViewBuilder
	private func content(for article: WatchArticleRecord) -> some View {
		if isLoadingBody {
			ProgressView()
				.frame(maxWidth: .infinity)
		} else {
			Text(bodyText?.isEmpty == false ? bodyText ?? article.textPreview : article.textPreview)
				.font(.body)
		}
	}

	@ViewBuilder
	private func footer(for article: WatchArticleRecord) -> some View {
		VStack(spacing: 8) {
			Button {
				store.markStarred(article.articleID, !article.starred)
			} label: {
				Label(article.starred ? "Unstar" : "Star", systemImage: article.starred ? "star.fill" : "star")
					.frame(maxWidth: .infinity)
			}
			.tint(.yellow)
			.animation(isLuminanceReduced ? nil : .default, value: article.starred)
			// Double-tap (S9/Ultra 2+) binds to the primary action, per the design's
			// save-for-later shortcut. Silent no-op on older hardware.
			.handGestureShortcut(.primaryAction)

			Button {
				store.markRead(article.articleID, false)
			} label: {
				Label("Mark Unread", systemImage: "circle")
					.frame(maxWidth: .infinity)
			}
			.disabled(!article.read)

			Button {
				// TODO(M3): send WatchMessage.openOnPhoneMessage(url:) via PhoneSession
				// when the phone is reachable, else queue via transferUserInfo.
			} label: {
				Label("Open on iPhone", systemImage: "iphone")
					.frame(maxWidth: .infinity)
			}
			.disabled(true)
		}
		.buttonStyle(.bordered)
	}

	private func loadBody() async {
		isLoadingBody = true
		defer { isLoadingBody = false }
		let url = store.contentFileURL(for: articleID)
		bodyText = await ArticleBodyPlainTextConverter.plainText(contentsOf: url)
	}
}

/// Converts an article's stored `contentHTML` into plain, readable text: strips tags and
/// decodes entities. No layout, no links, no block structure.
///
/// TODO(M3): replace with the block-based renderer described in Technotes/WatchApp.md
/// ("Article view") — an `ArticleBodyParser` producing `[BodyBlock]` (paragraphs, headings,
/// lists, code blocks, preserved link ranges) rendered as `AttributedString` per block.
enum ArticleBodyPlainTextConverter {

	static func plainText(contentsOf url: URL) async -> String? {
		await Task.detached(priority: .userInitiated) {
			guard let data = try? Data(contentsOf: url), let html = String(data: data, encoding: .utf8) else {
				return nil
			}
			return plainText(fromHTML: html)
		}.value
	}

	static func plainText(fromHTML html: String) -> String {
		let withoutScriptsAndStyles = removingScriptsAndStyles(from: html)
		let withLineBreaks = insertingLineBreaks(into: withoutScriptsAndStyles)
		let stripped = strippingTags(from: withLineBreaks)
		let decoded = decodingEntities(in: stripped)
		return collapsingWhitespace(in: decoded)
	}

	private static func removingScriptsAndStyles(from html: String) -> String {
		var result = html
		for tag in ["script", "style"] {
			let pattern = "(?is)<\(tag)\\b[^>]*>.*?</\(tag)>"
			result = result.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
		}
		return result
	}

	private static func insertingLineBreaks(into html: String) -> String {
		html.replacingOccurrences(of: "(?i)</?(p|br|div|li|h[1-6]|blockquote)[^>]*>", with: "\n", options: .regularExpression)
	}

	private static func strippingTags(from html: String) -> String {
		var result = ""
		result.reserveCapacity(html.count)
		var isInsideTag = false
		for character in html {
			switch character {
			case "<":
				isInsideTag = true
			case ">":
				isInsideTag = false
			default:
				if !isInsideTag {
					result.append(character)
				}
			}
		}
		return result
	}

	private static let namedEntities: [Substring: Character] = [
		"amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
		"nbsp": "\u{00A0}", "mdash": "\u{2014}", "ndash": "\u{2013}",
		"hellip": "\u{2026}", "lsquo": "\u{2018}", "rsquo": "\u{2019}",
		"ldquo": "\u{201C}", "rdquo": "\u{201D}", "copy": "\u{00A9}"
	]

	private static func decodingEntities(in string: String) -> String {
		guard string.contains("&") else {
			return string
		}

		var result = ""
		result.reserveCapacity(string.count)
		var index = string.startIndex

		while index < string.endIndex {
			let character = string[index]
			guard character == "&", let semicolonIndex = string[index...].firstIndex(of: ";") else {
				result.append(character)
				index = string.index(after: index)
				continue
			}

			let entity = string[string.index(after: index)..<semicolonIndex]
			if let scalar = numericScalar(for: entity) {
				result.append(Character(scalar))
			} else if let named = namedEntities[entity] {
				result.append(named)
			} else {
				result.append(contentsOf: string[index...semicolonIndex])
			}
			index = string.index(after: semicolonIndex)
		}

		return result
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

	private static func collapsingWhitespace(in string: String) -> String {
		let collapsedSpaces = string.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
		let collapsedBlankLines = collapsedSpaces.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
		return collapsedBlankLines.trimmingCharacters(in: .whitespacesAndNewlines)
	}
}
