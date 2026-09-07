//
//  ClearIconCaches.swift
//  NetNewsWire
//
//  Copyright © 2026 Ranchero Software. All rights reserved.
//

import Foundation
import Account
import HTMLMetadata
import Images
import RSWeb

extension AppDelegate {

	/// Empties every icon-related cache: the favicon and feed-icon downloaders’ in-memory and
	/// disk caches, the image downloader’s cache, the image-metadata database (including the
	/// download-failure table, which otherwise suppresses retries for several days), the
	/// HTML-metadata cache used for icon discovery, the shared HTTP response cache, and the
	/// UI-layer icon cache. Icons are downloaded again as feeds appear.
	@MainActor func clearAllIconCaches() async {
		FaviconDownloader.shared.resetCache()
		FeedIconDownloader.shared.resetCache()
		ImageDownloader.shared.resetCache()
		Downloader.shared.resetCache()
		await ImageMetadataDatabase.shared.resetCache()

		// Icon discovery reads the home page’s parsed <head>. Leaving that cached — especially
		// a failure record, which suppresses re-downloads for days — makes clearing everything
		// else a no-op for any feed whose icon is found by scraping.
		await HTMLMetadataDownloader.shared.resetCache()

		IconImageCache.shared.emptyCache()

		NotificationCenter.default.post(name: .FaviconDidBecomeAvailable, object: nil)

		// Kick off downloads again. Without this, feed icons stay empty — unlike favicons,
		// nothing re-requests them — and feeds silently fall back to their favicon.
		for account in AccountManager.shared.activeAccounts {
			IconImageCache.shared.prefetchImagesForFeeds(Array(account.flattenedFeeds()))
		}
	}
}
