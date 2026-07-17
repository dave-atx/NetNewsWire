//
//  WatchArticleRecord.swift
//  NetNewsWire
//
//  Created by Dave Marquard on 7/16/26.
//  Copyright © 2026 Ranchero Software, LLC. All rights reserved.
//

import Foundation

// Shared between the iOS app target and the watchOS app target — see Technotes/WatchApp.md.
// Foundation only: no UIKit/WatchKit.

/// One article as carried in a `WatchSnapshot`. The metadata fields are cheap to diff and
/// keep in memory; `contentHTML` is pre-trimmed to ~64 KB by the sender and is nil in
/// contexts where only metadata should travel (see `withoutContent`).
struct WatchArticleRecord: Codable, Equatable, Sendable, Identifiable {

	var id: String { articleID }

	let articleID: String
	let accountID: String
	let minifluxEntryID: Int?
	let feedName: String
	let title: String
	let textPreview: String
	let datePublished: Date?
	let url: String?
	let read: Bool
	let starred: Bool
	let contentHTML: String?

	init(articleID: String, accountID: String, minifluxEntryID: Int?, feedName: String, title: String, textPreview: String, datePublished: Date?, url: String?, read: Bool, starred: Bool, contentHTML: String?) {
		self.articleID = articleID
		self.accountID = accountID
		self.minifluxEntryID = minifluxEntryID
		self.feedName = feedName
		self.title = title
		self.textPreview = textPreview
		self.datePublished = datePublished
		self.url = url
		self.read = read
		self.starred = starred
		self.contentHTML = contentHTML
	}

	/// A copy with `contentHTML` removed, for contexts where only metadata should travel
	/// (the watch strips content into per-article files itself).
	var withoutContent: WatchArticleRecord {
		WatchArticleRecord(articleID: articleID, accountID: accountID, minifluxEntryID: minifluxEntryID, feedName: feedName, title: title, textPreview: textPreview, datePublished: datePublished, url: url, read: read, starred: starred, contentHTML: nil)
	}
}
