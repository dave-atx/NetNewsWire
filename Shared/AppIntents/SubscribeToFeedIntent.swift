//
//  SubscribeToFeedIntent.swift
//  NetNewsWire
//
//  The Add Feed action: subscribes to a feed directly and reports what happened.
//  Replaces AddFeedAppIntent, which is kept, hidden, for shortcuts saved with it.
//

import Foundation
import AppIntents
import RSCore
import Account

struct SubscribeToFeedIntent: AppIntent {

	static let title: LocalizedStringResource = "Add Feed"
	static let description = IntentDescription("Adds a feed to NetNewsWire. The URL can be the feed itself or a website that links to one.")

	@available(iOS 26.0, macOS 26.0, *)
	static var supportedModes: IntentModes {
		.background
	}

	@Parameter(title: LocalizedStringResource("URL", comment: "Label for a feed URL"))
	var url: URL

	@Parameter(title: "Account", description: "Defaults to the account you last added a feed to.")
	var account: AccountEntity?

	@Parameter(title: LocalizedStringResource("Folder", comment: "Label for choosing the folder a feed is added to"))
	var folder: FolderEntity?

	static var parameterSummary: some ParameterSummary {
		Summary("Add \(\.$url) to \(\.$account)") {
			\.$folder
		}
	}

	@MainActor
	func perform() async throws -> some IntentResult & ReturnsValue<FeedEntity> & ProvidesDialog {
		let container = try destinationContainer()
		guard let account = container.account else {
			throw SubscribeToFeedIntentError.noAccounts
		}

		let urlString = url.absoluteString.normalizedURL
		if account.existingFeed(withURL: urlString) != nil {
			throw SubscribeToFeedIntentError.alreadySubscribed(account: account.nameForDisplay)
		}

		let feed: Feed
		do {
			feed = try await withCheckedThrowingContinuation { continuation in
				account.createFeed(url: urlString, name: nil, container: container, validateFeed: true) { result in
					continuation.resume(with: result)
				}
			}
		} catch AccountError.createErrorAlreadySubscribed {
			throw SubscribeToFeedIntentError.alreadySubscribed(account: account.nameForDisplay)
		} catch AccountError.createErrorNotFound {
			throw SubscribeToFeedIntentError.noFeedFound(url: urlString)
		} catch {
			throw SubscribeToFeedIntentError.couldNotAdd(reason: error.localizedDescription)
		}

		let dialog: IntentDialog
		if let folder = container as? Folder {
			dialog = "Added \(feed.nameForDisplay) to \(folder.nameForDisplay) in \(account.nameForDisplay)."
		} else {
			dialog = "Added \(feed.nameForDisplay) to \(account.nameForDisplay)."
		}
		return .result(value: FeedEntity(feed: feed), dialog: dialog)
	}
}

private extension SubscribeToFeedIntent {

	/// The chosen folder, else the chosen account, else the Add Feed sheet’s remembered container.
	@MainActor func destinationContainer() throws -> Container {
		let defaultContainer = AddFeedDefaultContainer.defaultContainer

		if let folder {
			guard let folderAccount = AccountManager.shared.existingAccount(accountID: folder.id.accountID), folderAccount.isActive,
				  let destination = folderAccount.existingFolder(withDisplayName: folder.id.itemID) else {
				throw SubscribeToFeedIntentError.folderNotFound(folder: folder.name)
			}
			if let account, account.id != folderAccount.accountID {
				throw SubscribeToFeedIntentError.folderNotInAccount(folder: folder.name, account: account.name)
			}
			return destination
		}

		if let account {
			guard let chosenAccount = AccountManager.shared.existingAccount(accountID: account.id), chosenAccount.isActive else {
				throw SubscribeToFeedIntentError.accountNotFound(account: account.name)
			}
			// Prefer the remembered folder when it’s in this account, rather than the alphabetically first one.
			if let defaultContainer, defaultContainer.account?.accountID == chosenAccount.accountID {
				return defaultContainer
			}
			guard let destination = AddFeedDefaultContainer.substituteContainerIfNeeded(account: chosenAccount) else {
				throw SubscribeToFeedIntentError.noFolder(account: account.name)
			}
			return destination
		}

		guard let defaultContainer else {
			throw SubscribeToFeedIntentError.noAccounts
		}
		return defaultContainer
	}
}

enum SubscribeToFeedIntentError: Error, CustomLocalizedStringResourceConvertible {
	case noAccounts
	case accountNotFound(account: String)
	case folderNotFound(folder: String)
	case folderNotInAccount(folder: String, account: String)
	case noFolder(account: String)
	case alreadySubscribed(account: String)
	case noFeedFound(url: String)
	case couldNotAdd(reason: String)

	var localizedStringResource: LocalizedStringResource {
		switch self {
		case .noAccounts:
			return "There are no accounts to add the feed to."
		case .accountNotFound(let account):
			return "Couldn’t find the account “\(account)”."
		case .folderNotFound(let folder):
			return "Couldn’t find the folder “\(folder)”."
		case .folderNotInAccount(let folder, let account):
			return "The folder “\(folder)” isn’t in the account “\(account)”."
		case .noFolder(let account):
			return "“\(account)” needs feeds to go in a folder, and it doesn’t have any."
		case .alreadySubscribed(let account):
			return "You’ve already added this feed to “\(account)”."
		case .noFeedFound(let url):
			return "Couldn’t find a feed at \(url)."
		case .couldNotAdd(let reason):
			return "Couldn’t add the feed: \(reason)"
		}
	}
}
