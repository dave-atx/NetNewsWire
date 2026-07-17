//
//  TimelineView.swift
//  NetNewsWire Watch App
//
//  Copyright © 2026 Ranchero Software. All rights reserved.
//

import SwiftUI

// M1 scaffolding — see Technotes/WatchApp.md "Reading experience > Timeline".

/// Root timeline: two sections, Unread and Saved (starred). Reads the store's precomputed
/// `unread`/`starred` arrays directly — never filters or sorts inline here.
struct TimelineView: View {

	var store: WatchStore
	var coordinator: SyncCoordinator
	var phoneSession: PhoneSession

	var body: some View {
		Group {
			if store.unread.isEmpty && store.starred.isEmpty {
				EmptyTimelineView()
			} else {
				List {
					if !store.unread.isEmpty {
						Section("Unread") {
							ForEach(store.unread) { article in
								NavigationLink(value: article.id) {
									TimelineRowView(article: article, store: store)
								}
							}
						}
					}
					if !store.starred.isEmpty {
						Section("Saved") {
							ForEach(store.starred) { article in
								NavigationLink(value: article.id) {
									TimelineRowView(article: article, store: store)
								}
							}
						}
					}
				}
				.refreshable {
					await coordinator.manualSync()
				}
			}
		}
		.navigationDestination(for: String.self) { articleID in
			ArticleView(articleID: articleID, store: store, phoneSession: phoneSession)
		}
		.navigationTitle("NetNewsWire")
		.toolbar {
			ToolbarItem(placement: .topBarTrailing) {
				NavigationLink {
					SettingsView(coordinator: coordinator)
				} label: {
					Label("Settings", systemImage: "gear")
				}
			}
		}
	}
}

/// A single timeline row. Takes the record value (small, `Equatable`) rather than looking
/// itself up in the store, so row diffing stays cheap; `store` is only used inside swipe
/// action closures, never read during `body`, so it doesn't widen this row's invalidation.
struct TimelineRowView: View {

	var article: WatchArticleRecord
	var store: WatchStore

	@Environment(\.isLuminanceReduced) private var isLuminanceReduced

	var body: some View {
		HStack(alignment: .top, spacing: 6) {
			Circle()
				.fill(.tint)
				.frame(width: 6, height: 6)
				.padding(.top, 6)
				.opacity(article.read ? 0 : 1)
				.animation(isLuminanceReduced ? nil : .easeInOut, value: article.read)

			VStack(alignment: .leading, spacing: 2) {
				Text(article.feedName)
					.font(.caption2)
					.foregroundStyle(.secondary)
				Text(article.title)
					.font(.body)
					.lineLimit(3)
				if let datePublished = article.datePublished {
					Text(datePublished, format: .relative(presentation: .named))
						.font(.caption2)
						.foregroundStyle(.secondary)
				}
			}
		}
		.swipeActions(edge: .leading) {
			Button {
				store.markRead(article.articleID, !article.read)
			} label: {
				Label(article.read ? "Mark Unread" : "Mark Read", systemImage: article.read ? "circle" : "checkmark.circle")
			}
			.tint(.blue)
		}
		.swipeActions(edge: .trailing) {
			Button {
				store.markStarred(article.articleID, !article.starred)
			} label: {
				Label(article.starred ? "Unstar" : "Star", systemImage: article.starred ? "star.slash" : "star")
			}
			.tint(.yellow)
		}
	}
}

/// Shown when the cache has neither unread nor starred articles — first launch, or after
/// the phone hasn't synced anything down yet.
struct EmptyTimelineView: View {

	var body: some View {
		ContentUnavailableView {
			Label("No Articles", systemImage: "tray")
		} description: {
			Text("Open NetNewsWire on your iPhone to sync.")
		}
	}
}
