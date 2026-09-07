//
//  ClearIconCaches.swift
//  NetNewsWire
//
//  Copyright © 2026 Ranchero Software. All rights reserved.
//

import Foundation
import Account
import Images

extension AppDelegate {

	/// Empties every icon-related cache: the favicon and feed-icon downloaders’ in-memory and
	/// disk caches, the image downloader’s cache, the image-metadata database (including the
	/// download-failure table, which otherwise suppresses retries for several days), and the
	/// UI-layer icon cache. Icons are downloaded again as feeds appear.
	@MainActor func clearAllIconCaches() async {
		FaviconDownloader.shared.resetCache()
		FeedIconDownloader.shared.resetCache()
		ImageDownloader.shared.resetCache()
		await ImageMetadataDatabase.shared.resetCache()
		IconImageCache.shared.emptyCache()

		NotificationCenter.default.post(name: .FaviconDidBecomeAvailable, object: nil)

		// Kick off downloads again. Without this, feed icons stay empty — unlike favicons,
		// nothing re-requests them — and feeds silently fall back to their favicon.
		for account in AccountManager.shared.activeAccounts {
			IconImageCache.shared.prefetchImagesForFeeds(Array(account.flattenedFeeds()))
		}
	}
}
