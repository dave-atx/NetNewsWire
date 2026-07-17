//
//  WatchSchema.swift
//  NetNewsWire
//
//  Created by Dave Marquard on 7/16/26.
//  Copyright © 2026 Ranchero Software, LLC. All rights reserved.
//

import Foundation

// Shared between the iOS app target and the watchOS app target — see Technotes/WatchApp.md.
// Foundation only: no UIKit/WatchKit. Every WC payload and the article snapshot carry
// WatchSchema.version so the phone and watch (which can run mismatched versions for days)
// can reject-or-degrade on unknown versions rather than misparse.

/// Namespace for the watch wire schema: the version every payload carries, and the
/// dictionary keys used by WatchConnectivity messages and plist-safe encodings.
enum WatchSchema {

	static let version = 1

	enum Keys {
		static let schemaVersion = "schemaVersion"
		static let messageKind = "messageKind"

			static let accountID = "accountID"
			static let articleID = "articleID"
		static let minifluxEntryID = "minifluxEntryID"
		static let key = "key"
		static let flag = "flag"
		static let date = "date"

		static let statusBatch = "statusBatch"
		static let url = "url"

		static let accountConfig = "accountConfig"
		static let endpoint = "endpoint"
		static let serverVersion = "serverVersion"
		static let credentialType = "credentialType"
		static let username = "username"
		static let secret = "secret"
	}
}

/// Thrown when a decoded payload declares a `schemaVersion` newer than this build understands.
enum WatchSchemaError: Error, Sendable {
	case unsupportedVersion(Int)
}
