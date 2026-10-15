//
//  FolderEntity.swift
//  NetNewsWire
//
//  Exposes folders to Siri and Shortcuts, so intents can offer them as a picker.
//

import Foundation
import AppIntents
import Account

struct FolderEntity: AppEntity {

	static let typeDisplayRepresentation = TypeDisplayRepresentation(name: LocalizedStringResource("Folder", comment: "App Intents type name for a folder"))
	static let defaultQuery = FolderEntityQuery()

	/// Account ID plus folder name, matching how ContainerIdentifier identifies a folder.
	let id: AccountScopedEntityID

	@Property(title: "Name")
	var name: String

	@Property(title: "Account")
	var accountName: String

	var displayRepresentation: DisplayRepresentation {
		DisplayRepresentation(title: "\(name)", subtitle: "\(accountName)")
	}

	@MainActor init(folder: Folder, account: Account) {
		self.id = AccountScopedEntityID(accountID: account.accountID, itemID: folder.nameForDisplay)
		self.name = folder.nameForDisplay
		self.accountName = account.nameForDisplay
	}
}

struct FolderEntityQuery: EntityStringQuery {

	// Offer only the folders in the account the person picked (all accounts' folders until they pick one).
	@IntentParameterDependency<SubscribeToFeedIntent>(\.$account)
	var subscribeToFeedIntent

	@MainActor func entities(for identifiers: [AccountScopedEntityID]) async throws -> [FolderEntity] {
		identifiers.compactMap { identifier in
			guard let account = AccountManager.shared.existingAccount(accountID: identifier.accountID), account.isActive,
				  let folder = account.existingFolder(withDisplayName: identifier.itemID) else {
				return nil
			}
			return FolderEntity(folder: folder, account: account)
		}
	}

	@MainActor func entities(matching string: String) async throws -> [FolderEntity] {
		candidateFolders().filter { $0.name.localizedStandardContains(string) }
	}

	@MainActor func suggestedEntities() async throws -> [FolderEntity] {
		candidateFolders()
	}

	@MainActor private func candidateFolders() -> [FolderEntity] {
		let accounts: [Account]
		if let accountID = subscribeToFeedIntent?.account.id, let account = AccountManager.shared.existingAccount(accountID: accountID) {
			accounts = [account]
		} else {
			accounts = AccountManager.shared.sortedActiveAccounts
		}
		return accounts.flatMap { account in
			(account.sortedFolders ?? []).map { FolderEntity(folder: $0, account: account) }
		}
	}
}
