//
//  WatchSnapshot.swift
//  NetNewsWire
//
//  Created by Dave Marquard on 7/16/26.
//  Copyright © 2026 Ranchero Software, LLC. All rights reserved.
//

import Foundation

// Shared between the iOS app target and the watchOS app target — see Technotes/WatchApp.md.
// Foundation only: no UIKit/WatchKit.

/// The article cache the phone ships to the watch (relay path) or the watch assembles
/// itself (direct path). Both paths produce this same shape.
struct WatchSnapshot: Codable, Equatable, Sendable {

	let schemaVersion: Int
	let generatedAt: Date
	let articles: [WatchArticleRecord]

	init(generatedAt: Date, articles: [WatchArticleRecord]) {
		self.schemaVersion = WatchSchema.version
		self.generatedAt = generatedAt
		self.articles = articles
	}

	/// Reads just the `schemaVersion` field, so a payload can be rejected before the full
	/// decode is attempted.
	private struct VersionProbe: Decodable {
		let schemaVersion: Int
	}

	static func decode(from data: Data) throws -> WatchSnapshot {
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601

		let probe = try decoder.decode(VersionProbe.self, from: data)
		guard probe.schemaVersion <= WatchSchema.version else {
			throw WatchSchemaError.unsupportedVersion(probe.schemaVersion)
		}

		return try decoder.decode(WatchSnapshot.self, from: data)
	}

	func encoded() throws -> Data {
		let encoder = JSONEncoder()
		encoder.dateEncodingStrategy = .iso8601
		return try encoder.encode(self)
	}
}
