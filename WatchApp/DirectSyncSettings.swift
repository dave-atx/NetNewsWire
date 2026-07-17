//
//  DirectSyncSettings.swift
//  NetNewsWire Watch App
//
//  Copyright © 2026 Ranchero Software. All rights reserved.
//

import Foundation
import MinifluxAPI
import Secrets
import os

// M2 — see Technotes/WatchApp.md "Credential handoff (direct path)". The phone forwards a
// Miniflux account's non-secret config via the WC application context and its secret via a
// separate credential message. This type is the watch-side home for both: config and the
// credential's non-secret parts in UserDefaults, the secret in the watch's own keychain
// (the watch keychain is not shared with the phone; app-group keychain sharing doesn't
// span devices).

/// Watch-side storage for the direct Miniflux sync path: the phone-forwarded account
/// config and credential. `SyncCoordinator` reads `config`/`credentials` to decide whether
/// the direct path is available.
@MainActor
final class DirectSyncSettings {

	private enum Keys {
		static let accountID = "DirectSync.accountID"
		static let endpoint = "DirectSync.endpoint"
		static let serverVersion = "DirectSync.serverVersion"
		static let credentialAccountID = "DirectSync.credentialAccountID"
		static let credentialEndpoint = "DirectSync.credentialEndpoint"
		static let credentialType = "DirectSync.credentialType"
		static let credentialUsername = "DirectSync.credentialUsername"
	}

	private let userDefaults: UserDefaults
	private let logger = Logger(subsystem: WatchLog.subsystem, category: "DirectSyncSettings")

	init(userDefaults: UserDefaults = .standard) {
		self.userDefaults = userDefaults
	}

	// MARK: - Config (non-secret, from the application context)

	var config: WatchAccountConfig? {
		guard let accountID = userDefaults.string(forKey: Keys.accountID) else {
			return nil
		}
		guard let endpoint = userDefaults.string(forKey: Keys.endpoint) else {
			return nil
		}
		return WatchAccountConfig(accountID: accountID, endpoint: endpoint, serverVersion: userDefaults.string(forKey: Keys.serverVersion))
	}

	/// Applies a received application context's config. Latest wins; nil (no Miniflux
	/// account on the phone) clears the stored config. The credential is not touched here —
	/// its lifecycle is `storeCredential`/`removeCredential`, driven by separate messages.
	func applyConfig(_ config: WatchAccountConfig?) {
		guard let config else {
			userDefaults.removeObject(forKey: Keys.accountID)
			userDefaults.removeObject(forKey: Keys.endpoint)
			userDefaults.removeObject(forKey: Keys.serverVersion)
			return
		}
		userDefaults.set(config.accountID, forKey: Keys.accountID)
		userDefaults.set(config.endpoint, forKey: Keys.endpoint)
		userDefaults.set(config.serverVersion, forKey: Keys.serverVersion)
	}

	// MARK: - Credential (secret in the watch keychain)

	/// The stored Miniflux credential, if a complete one has been received. The secret
	/// lives in the watch keychain; only its non-secret coordinates are in UserDefaults.
	var credentials: Credentials? {
		guard let typeRawValue = userDefaults.string(forKey: Keys.credentialType), let type = CredentialsType(rawValue: typeRawValue) else {
			return nil
		}
		guard let endpoint = userDefaults.string(forKey: Keys.credentialEndpoint) else {
			return nil
		}
		guard let username = userDefaults.string(forKey: Keys.credentialUsername) else {
			return nil
		}
		do {
			return try CredentialsManager.retrieveCredentials(type: type, server: endpoint, username: username)
		} catch {
			logger.error("Failed to retrieve credential from the keychain: \(error.localizedDescription)")
			return nil
		}
	}

	func storeCredential(_ credential: WatchCredential) {
		guard let type = CredentialsType(rawValue: credential.credentialType) else {
			logger.error("Ignoring credential with unknown type")
			return
		}

		// If a previous credential lives under different keychain coordinates, remove it
		// first so stale secrets don't accumulate in the keychain.
		removeStoredKeychainItemIfCoordinatesDiffer(from: credential)

		do {
			try CredentialsManager.storeCredentials(Credentials(type: type, username: credential.username, secret: credential.secret), server: credential.endpoint)
		} catch {
			logger.error("Failed to store credential in the keychain: \(error.localizedDescription)")
			return
		}

		userDefaults.set(credential.accountID, forKey: Keys.credentialAccountID)
		userDefaults.set(credential.endpoint, forKey: Keys.credentialEndpoint)
		userDefaults.set(credential.credentialType, forKey: Keys.credentialType)
		userDefaults.set(credential.username, forKey: Keys.credentialUsername)
	}

	/// Handles a `credentialTombstone`: the account was removed on the phone, so delete the
	/// watch's copy of its secret and forget the coordinates.
	func removeCredential(accountID: String) {
		guard userDefaults.string(forKey: Keys.credentialAccountID) == accountID else {
			return
		}
		removeStoredKeychainItem()
		userDefaults.removeObject(forKey: Keys.credentialAccountID)
		userDefaults.removeObject(forKey: Keys.credentialEndpoint)
		userDefaults.removeObject(forKey: Keys.credentialType)
		userDefaults.removeObject(forKey: Keys.credentialUsername)
	}

	private func removeStoredKeychainItemIfCoordinatesDiffer(from credential: WatchCredential) {
		guard let storedEndpoint = userDefaults.string(forKey: Keys.credentialEndpoint),
			let storedType = userDefaults.string(forKey: Keys.credentialType),
			let storedUsername = userDefaults.string(forKey: Keys.credentialUsername) else {
			return
		}
		if storedEndpoint != credential.endpoint || storedType != credential.credentialType || storedUsername != credential.username {
			removeStoredKeychainItem()
		}
	}

	private func removeStoredKeychainItem() {
		guard let typeRawValue = userDefaults.string(forKey: Keys.credentialType), let type = CredentialsType(rawValue: typeRawValue) else {
			return
		}
		guard let endpoint = userDefaults.string(forKey: Keys.credentialEndpoint) else {
			return
		}
		guard let username = userDefaults.string(forKey: Keys.credentialUsername) else {
			return
		}
		do {
			try CredentialsManager.removeCredentials(type: type, server: endpoint, username: username)
		} catch {
			logger.error("Failed to remove credential from the keychain: \(error.localizedDescription)")
		}
	}
}

// MARK: - MinifluxAccountSettingsProviding

/// Lets a `MinifluxAPICaller` read the phone-forwarded endpoint and server version. The
/// setter side of `detectedServerVersion` exists for the protocol; the watch never runs
/// version detection itself (per the design, the phone's detected version is authoritative),
/// but if the caller ever writes one it's persisted the same way.
extension DirectSyncSettings: MinifluxAccountSettingsProviding {

	var endpointURL: URL? {
		guard let config else {
			return nil
		}
		return URL(string: config.endpoint)
	}

	var detectedServerVersion: String? {
		get {
			userDefaults.string(forKey: Keys.serverVersion)
		}
		set {
			userDefaults.set(newValue, forKey: Keys.serverVersion)
		}
	}
}
