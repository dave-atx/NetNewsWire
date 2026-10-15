//
//  FeedEntity.swift
//  NetNewsWire
//
//  Exposes feeds to Siri, Shortcuts, and Apple Intelligence.
//

import Foundation
import AppIntents
import Account

struct FeedEntity: AppEntity {

	static let typeDisplayRepresentation = TypeDisplayRepresentation(name: LocalizedStringResource("Feed", comment: "App Intents type name for a feed"))
	static let defaultQuery = FeedEntityQuery()

	let id: AccountScopedEntityID

	@Property(title: "Name")
	var name: String

	@Property(title: "Account")
	var accountName: String

	@Property(title: LocalizedStringResource("URL", comment: "Label for a feed URL"))
	var url: URL?

	@Property(title: "Home Page")
	var homePageURL: URL?

	@Property(title: "Unread Count")
	var unreadCount: Int

	var displayRepresentation: DisplayRepresentation {
		DisplayRepresentation(title: "\(name)", subtitle: "\(accountName)")
	}

	@MainActor init(feed: Feed) {
		self.id = AccountScopedEntityID(feed: feed)
		self.name = feed.nameForDisplay
		self.accountName = feed.account?.nameForDisplay ?? ""
		self.url = URL(string: feed.url)
		self.homePageURL = feed.homePageURL.flatMap { URL(string: $0) }
		self.unreadCount = feed.unreadCount
	}
}

extension AccountScopedEntityID {

	init(feed: Feed) {
		self.init(accountID: feed.accountID, itemID: feed.feedID)
	}
}

struct FeedEntityQuery: EntityStringQuery {

	@MainActor func entities(for identifiers: [AccountScopedEntityID]) async throws -> [FeedEntity] {
		identifiers.compactMap { identifier in
			AccountManager.shared.existingAccount(accountID: identifier.accountID)?.existingFeed(withFeedID: identifier.itemID)
		}.map { FeedEntity(feed: $0) }
	}

	@MainActor func entities(matching string: String) async throws -> [FeedEntity] {
		allFeeds().filter { $0.nameForDisplay.localizedStandardContains(string) }.map { FeedEntity(feed: $0) }
	}

	@MainActor func suggestedEntities() async throws -> [FeedEntity] {
		allFeeds().map { FeedEntity(feed: $0) }
	}

	@MainActor private func allFeeds() -> [Feed] {
		AccountManager.shared.sortedActiveAccounts.flatMap { account in
			account.flattenedFeeds().sorted { $0.nameForDisplay.localizedStandardCompare($1.nameForDisplay) == .orderedAscending }
		}
	}
}
