//
//  AccountEntity.swift
//  NetNewsWire
//
//  Exposes accounts to Siri and Shortcuts, so intents can offer them as a picker.
//

import Foundation
import AppIntents
import Account

struct AccountEntity: AppEntity {

	static let typeDisplayRepresentation = TypeDisplayRepresentation(name: LocalizedStringResource("Account", comment: "App Intents type name for an account"))
	static let defaultQuery = AccountEntityQuery()

	let id: String

	@Property(title: "Name")
	var name: String

	var displayRepresentation: DisplayRepresentation {
		DisplayRepresentation(title: "\(name)")
	}

	@MainActor init(account: Account) {
		self.id = account.accountID
		self.name = account.nameForDisplay
	}
}

struct AccountEntityQuery: EntityStringQuery {

	@MainActor func entities(for identifiers: [String]) async throws -> [AccountEntity] {
		identifiers.compactMap { AccountManager.shared.existingAccount(accountID: $0) }
			.filter { $0.isActive }
			.map { AccountEntity(account: $0) }
	}

	@MainActor func entities(matching string: String) async throws -> [AccountEntity] {
		AccountManager.shared.sortedActiveAccounts
			.filter { $0.nameForDisplay.localizedStandardContains(string) }
			.map { AccountEntity(account: $0) }
	}

	@MainActor func suggestedEntities() async throws -> [AccountEntity] {
		AccountManager.shared.sortedActiveAccounts.map { AccountEntity(account: $0) }
	}
}
