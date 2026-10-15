//
//  AccountScopedEntityID.swift
//  NetNewsWire
//
//  Identifies an App Intents entity — a feed or an article — that belongs to an account.
//

import Foundation
import AppIntents

/// The system stores `entityIdentifierString` in saved shortcuts, donations, and the
/// onscreen-entity annotation, so its format must never change.
struct AccountScopedEntityID: EntityIdentifierConvertible, Hashable, Sendable {

	let accountID: String
	let itemID: String

	// Account IDs are UUIDs, "OnMyMac", or "iCloud", so they never contain a slash.
	// Feed and article IDs can (feed IDs are often URLs), so split on the first slash.
	var entityIdentifierString: String {
		"\(accountID)/\(itemID)"
	}

	static func entityIdentifier(for entityIdentifierString: String) -> AccountScopedEntityID? {
		guard let separatorIndex = entityIdentifierString.firstIndex(of: "/") else {
			return nil
		}
		let accountID = String(entityIdentifierString[..<separatorIndex])
		let itemID = String(entityIdentifierString[entityIdentifierString.index(after: separatorIndex)...])
		guard !accountID.isEmpty, !itemID.isEmpty else {
			return nil
		}
		return AccountScopedEntityID(accountID: accountID, itemID: itemID)
	}
}
