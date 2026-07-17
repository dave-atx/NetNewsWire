//
//  WatchStatusChange.swift
//  NetNewsWire
//
//  Created by Dave Marquard on 7/16/26.
//  Copyright © 2026 Ranchero Software, LLC. All rights reserved.
//

import Foundation

// Shared between the iOS app target and the watchOS app target — see Technotes/WatchApp.md.
// Foundation only: no UIKit/WatchKit.
//
// These travel over WCSession sendMessage/transferUserInfo, which require plist-safe
// dictionaries (String/NSNumber/NSString/NSData/NSDate/NSArray/NSDictionary) rather than
// arbitrary Codable payloads, so each type below carries its own dictionary round-trip
// alongside its Codable conformance.

/// Which flag a `WatchStatusChange` toggles.
enum WatchStatusKey: String, Codable, Sendable {
	case read
	case starred
}

/// A single read/star action queued on the watch and relayed to the phone (or sent
/// directly to Miniflux). `minifluxEntryID` lets the direct path address the entry
/// without a lookup table.
struct WatchStatusChange: Codable, Equatable, Sendable {

	let articleID: String
	let accountID: String
	let minifluxEntryID: Int?
	let key: WatchStatusKey
	let flag: Bool
	let date: Date

	init(articleID: String, accountID: String, minifluxEntryID: Int?, key: WatchStatusKey, flag: Bool, date: Date) {
		self.articleID = articleID
		self.accountID = accountID
		self.minifluxEntryID = minifluxEntryID
		self.key = key
		self.flag = flag
		self.date = date
	}

	var dictionaryRepresentation: [String: Any] {
		var dictionary: [String: Any] = [
			WatchSchema.Keys.schemaVersion: WatchSchema.version,
			WatchSchema.Keys.articleID: articleID,
			WatchSchema.Keys.accountID: accountID,
			WatchSchema.Keys.key: key.rawValue,
			WatchSchema.Keys.flag: flag,
			WatchSchema.Keys.date: date
		]
		if let minifluxEntryID {
			dictionary[WatchSchema.Keys.minifluxEntryID] = minifluxEntryID
		}
		return dictionary
	}

	/// Returns nil if the dictionary is missing required fields or declares a
	/// `schemaVersion` newer than this build understands.
	init?(dictionary: [String: Any]) {
		guard let schemaVersion = dictionary[WatchSchema.Keys.schemaVersion] as? Int, schemaVersion <= WatchSchema.version else {
			return nil
		}
		guard let articleID = dictionary[WatchSchema.Keys.articleID] as? String else {
			return nil
		}
		guard let accountID = dictionary[WatchSchema.Keys.accountID] as? String else {
			return nil
		}
		guard let keyRawValue = dictionary[WatchSchema.Keys.key] as? String, let key = WatchStatusKey(rawValue: keyRawValue) else {
			return nil
		}
		guard let flag = dictionary[WatchSchema.Keys.flag] as? Bool else {
			return nil
		}
		guard let date = dictionary[WatchSchema.Keys.date] as? Date else {
			return nil
		}

		self.articleID = articleID
		self.accountID = accountID
		self.minifluxEntryID = dictionary[WatchSchema.Keys.minifluxEntryID] as? Int
		self.key = key
		self.flag = flag
		self.date = date
	}
}

/// A batch of queued status changes, for a single WatchConnectivity delivery.
struct WatchStatusBatch: Codable, Equatable, Sendable {

	let changes: [WatchStatusChange]

	init(changes: [WatchStatusChange]) {
		self.changes = changes
	}

	var dictionaryRepresentation: [String: Any] {
		[
			WatchSchema.Keys.schemaVersion: WatchSchema.version,
			WatchSchema.Keys.statusBatch: changes.map { $0.dictionaryRepresentation }
		]
	}

	/// Returns nil if the dictionary declares a `schemaVersion` newer than this build
	/// understands or is missing the batch array. Individual malformed changes within the
	/// batch are dropped rather than failing the whole batch.
	init?(dictionary: [String: Any]) {
		guard let schemaVersion = dictionary[WatchSchema.Keys.schemaVersion] as? Int, schemaVersion <= WatchSchema.version else {
			return nil
		}
		guard let rawChanges = dictionary[WatchSchema.Keys.statusBatch] as? [[String: Any]] else {
			return nil
		}

		self.changes = rawChanges.compactMap { WatchStatusChange(dictionary: $0) }
	}
}
