//
//  ArticleEntity.swift
//  NetNewsWire
//
//  Exposes articles to Siri, Shortcuts, and Apple Intelligence.
//

import Foundation
import AppIntents
import CoreTransferable
import UniformTypeIdentifiers
import RSCore
import Account
import Articles

struct ArticleEntity: AppEntity {

	static let typeDisplayRepresentation = TypeDisplayRepresentation(name: LocalizedStringResource("Article", comment: "App Intents type name for an article"))
	static let defaultQuery = ArticleEntityQuery()

	let id: AccountScopedEntityID

	@Property(title: "Title")
	var title: String

	@Property(title: "Feed")
	var feedName: String

	@Property(title: "Author")
	var byline: String?

	@Property(title: "URL")
	var url: URL?

	@Property(title: "Date Published")
	var datePublished: Date

	@Property(title: "Read")
	var isRead: Bool

	@Property(title: "Starred")
	var isStarred: Bool

	/// The article as plain text — what Siri and Apple Intelligence read when asked about “this” article.
	let plainText: String
	let contentHTML: String?

	var displayRepresentation: DisplayRepresentation {
		DisplayRepresentation(title: "\(title)", subtitle: "\(feedName)")
	}

	@MainActor init(article: Article) {
		let formatter = ArticleStringFormatter.shared
		var title = formatter.truncatedTitle(article)
		if title.isEmpty {
			title = formatter.truncatedSummary(article)
		}
		if title.isEmpty {
			title = NSLocalizedString("Untitled", comment: "Title for an article that has neither a title nor a summary")
		}

		// Plain stored properties first: assigning an @Property goes through self.
		self.id = AccountScopedEntityID(article: article)
		self.plainText = Self.plainText(for: article, title: title)
		self.contentHTML = article.contentHTML

		self.title = title
		self.feedName = article.feed?.nameForDisplay ?? ""
		self.byline = article.authors.flatMap { authors in
			let names = authors.compactMap { $0.name }.sorted()
			return names.isEmpty ? nil : names.joined(separator: ", ")
		}
		self.url = article.preferredURL
		self.datePublished = article.logicalDatePublished
		self.isRead = article.status.read
		self.isStarred = article.status.starred
	}
}

extension ArticleEntity: Transferable {

	static var transferRepresentation: some TransferRepresentation {
		DataRepresentation(exportedContentType: .plainText) { entity in
			Data(entity.plainText.utf8)
		}
		DataRepresentation(exportedContentType: .html) { entity in
			Data((entity.contentHTML ?? "").utf8)
		}
		.exportingCondition { $0.contentHTML != nil }
	}
}

private extension ArticleEntity {

	@MainActor static func plainText(for article: Article, title: String) -> String {
		var s = "\(title)\n\n"

		if let text = article.contentText {
			s += "\(text)\n\n"
		} else if let body = article.contentHTML ?? article.summary {
			s += "\(body.convertingToPlainText().decodingHTMLEntities())\n\n"
		}

		if let link = article.preferredLink {
			s += "\(link)\n"
		}

		return s
	}
}

extension AccountScopedEntityID {

	init(article: Article) {
		self.init(accountID: article.accountID, itemID: article.articleID)
	}
}

struct ArticleEntityQuery: EntityStringQuery {

	private static let maxResults = 50

	@MainActor func entities(for identifiers: [AccountScopedEntityID]) async throws -> [ArticleEntity] {
		let articleIDsByAccountID = Dictionary(grouping: identifiers, by: \.accountID).mapValues { Set($0.map(\.itemID)) }

		var entities = [ArticleEntity]()
		for (accountID, articleIDs) in articleIDsByAccountID {
			guard let account = AccountManager.shared.existingAccount(accountID: accountID) else {
				continue
			}
			let articles = await account.fetchArticlesAsync(.articleIDs(articleIDs))
			entities += articles.map { ArticleEntity(article: $0) }
		}
		return entities
	}

	@MainActor func entities(matching string: String) async throws -> [ArticleEntity] {
		let articles = await AccountManager.shared.fetchArticlesAsync(.search(string))
		return Self.newestFirst(articles)
	}

	@MainActor func suggestedEntities() async throws -> [ArticleEntity] {
		let articles = await AccountManager.shared.fetchArticlesAsync(.unread(Self.maxResults))
		return Self.newestFirst(articles)
	}

	@MainActor private static func newestFirst(_ articles: Set<Article>) -> [ArticleEntity] {
		articles
			.sorted { $0.logicalDatePublished > $1.logicalDatePublished }
			.prefix(maxResults)
			.map { ArticleEntity(article: $0) }
	}
}
