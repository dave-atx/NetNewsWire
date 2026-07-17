//
//  WatchAccountConfig.swift
//  NetNewsWire
//
//  Created by Dave Marquard on 7/16/26.
//  Copyright © 2026 Ranchero Software, LLC. All rights reserved.
//

import Foundation

// Shared between the iOS app target and the watchOS app target — see Technotes/WatchApp.md
// "Credential handoff (direct path)". Foundation only: no UIKit/WatchKit.
//
// The non-secret account config travels via `updateApplicationContext` (latest-wins,
// persisted indefinitely by WatchConnectivity on both devices). The secret travels
// separately as a `credential` message — never in the application context, because a
// credential shouldn't live in a plist that's re-delivered forever.

/// Non-secret Miniflux account configuration the phone forwards to the watch: which
/// account, where its server is, and the server version the phone last detected. The
/// watch runs no version detection of its own.
struct WatchAccountConfig: Equatable, Sendable {

	let accountID: String
	/// The account's endpoint URL, as an absolute string.
	let endpoint: String
	/// Raw server version string as detected by the phone (nil if never detected).
	let serverVersion: String?

	init(accountID: String, endpoint: String, serverVersion: String?) {
		self.accountID = accountID
		self.endpoint = endpoint
		self.serverVersion = serverVersion
	}

	var dictionaryRepresentation: [String: Any] {
		var dictionary: [String: Any] = [
			WatchSchema.Keys.accountID: accountID,
			WatchSchema.Keys.endpoint: endpoint
		]
		if let serverVersion {
			dictionary[WatchSchema.Keys.serverVersion] = serverVersion
		}
		return dictionary
	}

	init?(dictionary: [String: Any]) {
		guard let accountID = dictionary[WatchSchema.Keys.accountID] as? String else {
			return nil
		}
		guard let endpoint = dictionary[WatchSchema.Keys.endpoint] as? String else {
			return nil
		}

		self.accountID = accountID
		self.endpoint = endpoint
		self.serverVersion = dictionary[WatchSchema.Keys.serverVersion] as? String
	}

	/// The full application-context payload. A nil config produces a context that tells the
	/// watch "no Miniflux account" — the watch clears its stored config (the credential is
	/// deleted separately, by a `credentialTombstone` message).
	static func applicationContext(for config: WatchAccountConfig?) -> [String: Any] {
		var context: [String: Any] = [
			WatchSchema.Keys.schemaVersion: WatchSchema.version
		]
		if let config {
			context[WatchSchema.Keys.accountConfig] = config.dictionaryRepresentation
		}
		return context
	}

	/// Parses a received application context. Returns nil (no config) both for a context
	/// that explicitly carries none and for one with an unsupported newer schema version —
	/// a watch that can't parse the config must not attempt direct sync with it.
	static func config(fromApplicationContext context: [String: Any]) -> WatchAccountConfig? {
		guard let schemaVersion = context[WatchSchema.Keys.schemaVersion] as? Int, schemaVersion <= WatchSchema.version else {
			return nil
		}
		guard let configDictionary = context[WatchSchema.Keys.accountConfig] as? [String: Any] else {
			return nil
		}
		return WatchAccountConfig(dictionary: configDictionary)
	}
}

/// A Miniflux credential in flight from phone to watch. `Credentials` (Modules/Secrets)
/// isn't Codable, so the wire format is this plist-safe dictionary; the watch stores the
/// secret in its own keychain on receipt and persists it nowhere else.
struct WatchCredential: Equatable, Sendable {

	let accountID: String
	/// The account's endpoint URL string — carried here so keychain storage doesn't depend
	/// on the application context (which can arrive in any order relative to this message).
	let endpoint: String
	/// `CredentialsType` raw value, e.g. "minifluxAPIToken".
	let credentialType: String
	let username: String
	let secret: String

	init(accountID: String, endpoint: String, credentialType: String, username: String, secret: String) {
		self.accountID = accountID
		self.endpoint = endpoint
		self.credentialType = credentialType
		self.username = username
		self.secret = secret
	}

	var dictionaryRepresentation: [String: Any] {
		[
			WatchSchema.Keys.schemaVersion: WatchSchema.version,
			WatchSchema.Keys.messageKind: WatchMessageKind.credential.rawValue,
			WatchSchema.Keys.accountID: accountID,
			WatchSchema.Keys.endpoint: endpoint,
			WatchSchema.Keys.credentialType: credentialType,
			WatchSchema.Keys.username: username,
			WatchSchema.Keys.secret: secret
		]
	}

	init?(dictionary: [String: Any]) {
		guard let schemaVersion = dictionary[WatchSchema.Keys.schemaVersion] as? Int, schemaVersion <= WatchSchema.version else {
			return nil
		}
		guard WatchMessage.kind(of: dictionary) == .credential else {
			return nil
		}
		guard let accountID = dictionary[WatchSchema.Keys.accountID] as? String else {
			return nil
		}
		guard let endpoint = dictionary[WatchSchema.Keys.endpoint] as? String else {
			return nil
		}
		guard let credentialType = dictionary[WatchSchema.Keys.credentialType] as? String else {
			return nil
		}
		guard let username = dictionary[WatchSchema.Keys.username] as? String else {
			return nil
		}
		guard let secret = dictionary[WatchSchema.Keys.secret] as? String else {
			return nil
		}

		self.accountID = accountID
		self.endpoint = endpoint
		self.credentialType = credentialType
		self.username = username
		self.secret = secret
	}
}
