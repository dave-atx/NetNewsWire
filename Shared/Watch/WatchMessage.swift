//
//  WatchMessage.swift
//  NetNewsWire
//
//  Created by Dave Marquard on 7/16/26.
//  Copyright © 2026 Ranchero Software, LLC. All rights reserved.
//

import Foundation

// Shared between the iOS app target and the watchOS app target — see Technotes/WatchApp.md.
// Foundation only: no UIKit/WatchKit.
//
// The wire schema for WCSession message dictionaries used in M1. This is deliberately
// minimal — a set of builders and parsers, not a framework. Credential handoff messages
// (the secret side of the direct-Miniflux-path credential handoff) come in M2; they are
// not modeled here yet.

/// The kind of message a WCSession dictionary payload carries, identified by
/// `WatchSchema.Keys.messageKind`.
enum WatchMessageKind: String, Sendable {
	/// Watch → phone: a batch of queued read/star changes.
	case statusBatch
	/// Watch → phone: ask for a fresh article snapshot.
	case requestSnapshot
	/// Watch → phone: open a URL string on the phone.
	case openOnPhone
	/// Phone → watch: a Miniflux credential for the direct sync path (see
	/// `WatchCredential`). Sent via sendMessage/transferUserInfo, never the application
	/// context.
	case credential
	/// Phone → watch: the account was removed; delete the watch's stored credential copy.
	case credentialTombstone
}

/// Builders and parsers for the WCSession message dictionaries used in M1.
enum WatchMessage {

	static func kind(of dictionary: [String: Any]) -> WatchMessageKind? {
		guard let rawValue = dictionary[WatchSchema.Keys.messageKind] as? String else {
			return nil
		}
		return WatchMessageKind(rawValue: rawValue)
	}

	// MARK: - statusBatch

	static func statusBatchMessage(_ batch: WatchStatusBatch) -> [String: Any] {
		var dictionary = batch.dictionaryRepresentation
		dictionary[WatchSchema.Keys.messageKind] = WatchMessageKind.statusBatch.rawValue
		return dictionary
	}

	static func statusBatch(from dictionary: [String: Any]) -> WatchStatusBatch? {
		guard kind(of: dictionary) == .statusBatch else {
			return nil
		}
		return WatchStatusBatch(dictionary: dictionary)
	}

	// MARK: - requestSnapshot

	static func requestSnapshotMessage() -> [String: Any] {
		[
			WatchSchema.Keys.messageKind: WatchMessageKind.requestSnapshot.rawValue,
			WatchSchema.Keys.schemaVersion: WatchSchema.version
		]
	}

	static func isRequestSnapshot(_ dictionary: [String: Any]) -> Bool {
		kind(of: dictionary) == .requestSnapshot
	}

	// MARK: - credentialTombstone

	static func credentialTombstoneMessage(accountID: String) -> [String: Any] {
		[
			WatchSchema.Keys.messageKind: WatchMessageKind.credentialTombstone.rawValue,
			WatchSchema.Keys.schemaVersion: WatchSchema.version,
			WatchSchema.Keys.accountID: accountID
		]
	}

	static func credentialTombstoneAccountID(from dictionary: [String: Any]) -> String? {
		guard kind(of: dictionary) == .credentialTombstone else {
			return nil
		}
		return dictionary[WatchSchema.Keys.accountID] as? String
	}

	// MARK: - openOnPhone

	static func openOnPhoneMessage(url: String) -> [String: Any] {
		[
			WatchSchema.Keys.messageKind: WatchMessageKind.openOnPhone.rawValue,
			WatchSchema.Keys.schemaVersion: WatchSchema.version,
			WatchSchema.Keys.url: url
		]
	}

	static func openOnPhoneURL(from dictionary: [String: Any]) -> String? {
		guard kind(of: dictionary) == .openOnPhone else {
			return nil
		}
		return dictionary[WatchSchema.Keys.url] as? String
	}
}
