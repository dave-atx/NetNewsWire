//
//  ArticleBodyPlainTextConverter.swift
//  NetNewsWire Watch App
//
//  Copyright © 2026 Ranchero Software. All rights reserved.
//

import Foundation

/// Converts article `contentHTML` into plain, readable text: strips tags and decodes
/// entities. No layout, no links, no block structure. The article view renders blocks via
/// `ArticleBodyParser`; this survives it for one job — generating the short `textPreview`
/// shown in timeline rows when the watch builds records itself (direct Miniflux sync).
enum ArticleBodyPlainTextConverter {

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
