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

	@Property(title: "Type")
	var typeName: String

	let iconData: Data?

	var displayRepresentation: DisplayRepresentation {
		// Don't repeat the type when the account still has its default name.
		let subtitle: LocalizedStringResource? = typeName == name ? nil : "\(typeName)"
		return DisplayRepresentation(title: "\(name)", subtitle: subtitle, image: iconData.map { DisplayRepresentation.Image(data: $0) })
	}

	@MainActor init(account: Account) {
		// Plain stored properties first: assigning an @Property goes through self.
		self.id = account.accountID
		self.iconData = Assets.accountImage(account.type).dataRepresentation()

		self.name = account.nameForDisplay
		self.typeName = account.type.displayName
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
			.filter { $0.nameForDisplay.localizedStandardContains(string) || $0.type.displayName.localizedStandardContains(string) }
			.map { AccountEntity(account: $0) }
	}

	@MainActor func suggestedEntities() async throws -> [AccountEntity] {
		AccountManager.shared.sortedActiveAccounts.map { AccountEntity(account: $0) }
	}
}
