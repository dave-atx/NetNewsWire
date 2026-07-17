//
//  ArticleView.swift
//  NetNewsWire Watch App
//
//  Copyright © 2026 Ranchero Software. All rights reserved.
//

import SwiftUI

// M3 — see Technotes/WatchApp.md "Reading experience > Article view". Feed-provided content
// only (no extraction pass); the body renders as native blocks via ArticleBodyParser.

/// Article reading view. Loads its content file on demand from the store and parses it into
/// `BodyBlock`s off the main actor (once, cached in view state); header/footer read only the
/// metadata already in memory. Link taps can't open a browser on watchOS — they offer
/// Open on iPhone or Star instead, so links never dead-end.
struct ArticleView: View {

	let articleID: String
	var store: WatchStore
	var phoneSession: PhoneSession

	@State private var bodyBlocks: [BodyBlock]?
	@State private var isLoadingBody = true
	@State private var tappedLinkURL: URL?

	@Environment(\.isLuminanceReduced) private var isLuminanceReduced

	@AppStorage(WatchSettingsKeys.themeName) private var themeName = WatchTheme.defaultTheme.name
	@AppStorage(WatchSettingsKeys.markReadOnScroll) private var markReadOnScroll = false

	private var theme: WatchTheme {
		WatchTheme.theme(named: themeName)
	}

	private var article: WatchArticleRecord? {
		store.article(for: articleID)
	}

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 8) {
				if let article {
					header(for: article)
					Divider()
					content(for: article)
					endOfArticleSentinel(for: article)
					Divider()
					footer(for: article)
				} else {
					Text("This article is no longer available.")
						.foregroundStyle(.secondary)
				}
			}
			.padding(.horizontal, 2)
		}
		.containerBackground(theme.backgroundColor.color, for: .navigation)
		.confirmationDialog("Link", isPresented: isShowingLinkDialog, titleVisibility: .visible) {
			Button("Open on iPhone") {
				if let tappedLinkURL {
					phoneSession.sendOpenOnPhone(urlString: tappedLinkURL.absoluteString)
				}
			}
			Button("Star This Article") {
				store.markStarred(articleID, true)
			}
			Button("Cancel", role: .cancel) {}
		} message: {
			Text(tappedLinkURL?.absoluteString ?? "")
		}
		.navigationTitle(article?.feedName ?? "Article")
		.task(id: articleID) {
			await loadBody()
		}
		.onAppear {
			store.setOpenArticle(articleID)
		}
		.onDisappear {
			store.setOpenArticle(nil)
		}
	}

	@ViewBuilder
	private func header(for article: WatchArticleRecord) -> some View {
		VStack(alignment: .leading, spacing: 4) {
			Text(article.title)
				.font(.headline)
				.foregroundStyle(theme.textColor.color)
			HStack(spacing: 4) {
				Text(article.feedName)
				if let datePublished = article.datePublished {
					Text("·")
					Text(datePublished, format: .dateTime.month(.abbreviated).day())
				}
			}
			.font(.caption2)
			.foregroundStyle(theme.secondaryTextColor.color)
		}
	}

	/// Auto-mark-read, per the design: an end-of-article sentinel whose scroll visibility
	/// marks the article read — only when the setting is on (default is explicit marking)
	/// and only once the body has actually rendered, so a short article doesn't get marked
	/// by the loading placeholder's brief appearance.
	@ViewBuilder
	private func endOfArticleSentinel(for article: WatchArticleRecord) -> some View {
		Color.clear
			.frame(height: 1)
			.onScrollVisibilityChange { visible in
				if visible && markReadOnScroll && !isLoadingBody && !article.read {
					store.markRead(article.articleID, true)
				}
			}
	}

	/// A binding for the link dialog derived from the tapped URL, cleared on dismissal.
	private var isShowingLinkDialog: Binding<Bool> {
		Binding {
			tappedLinkURL != nil
		} set: { isShowing in
			if !isShowing {
				tappedLinkURL = nil
			}
		}
	}

	@ViewBuilder
	private func content(for article: WatchArticleRecord) -> some View {
		if isLoadingBody {
			ProgressView()
				.frame(maxWidth: .infinity)
		} else if let bodyBlocks, !bodyBlocks.isEmpty {
			// Long articles are hundreds of blocks — build rows lazily, per the design.
			LazyVStack(alignment: .leading, spacing: 8) {
				ForEach(bodyBlocks) { block in
					BodyBlockView(block: block, theme: theme)
				}
			}
			.fontDesign(theme.bodyFont.fontDesign)
			.foregroundStyle(theme.textColor.color)
			.tint(theme.linkColor.color)
			.environment(\.openURL, OpenURLAction { url in
				tappedLinkURL = url
				return .handled
			})
		} else {
			Text(article.textPreview)
				.font(.body)
				.fontDesign(theme.bodyFont.fontDesign)
				.foregroundStyle(theme.textColor.color)
		}
	}

	@ViewBuilder
	private func footer(for article: WatchArticleRecord) -> some View {
		VStack(spacing: 8) {
			Button {
				store.markStarred(article.articleID, !article.starred)
			} label: {
				Label(article.starred ? "Unstar" : "Star", systemImage: article.starred ? "star.fill" : "star")
					.frame(maxWidth: .infinity)
			}
			.tint(.yellow)
			.animation(isLuminanceReduced ? nil : .default, value: article.starred)
			// Double-tap (S9/Ultra 2+) binds to the primary action, per the design's
			// save-for-later shortcut. Silent no-op on older hardware.
			.handGestureShortcut(.primaryAction)

			Button {
				store.markRead(article.articleID, !article.read)
			} label: {
				Label(article.read ? "Mark Unread" : "Mark Read", systemImage: article.read ? "circle" : "checkmark.circle")
					.frame(maxWidth: .infinity)
			}
			.tint(theme.accentColor.color)

			Button {
				if let url = article.url {
					phoneSession.sendOpenOnPhone(urlString: url)
				}
			} label: {
				Label("Open on iPhone", systemImage: "iphone")
					.frame(maxWidth: .infinity)
			}
			.tint(theme.accentColor.color)
			.disabled(article.url == nil)
		}
		.buttonStyle(.bordered)
	}

	private func loadBody() async {
		isLoadingBody = true
		defer { isLoadingBody = false }
		let url = store.contentFileURL(for: articleID)
		bodyBlocks = await ArticleBodyParser.blocks(contentsOf: url)
	}
}

/// Renders one parsed `BodyBlock`. Text color and font design arrive from the enclosing
/// container; the theme is passed in for the accents (quote bar, list markers, secondary
/// text) that differ per block kind.
struct BodyBlockView: View {

	let block: BodyBlock
	let theme: WatchTheme

	var body: some View {
		switch block.kind {
		case .paragraph(let text):
			Text(text)
				.font(.body)
		case .heading(let level, let text):
			Text(text)
				.font(level <= 2 ? .headline : .subheadline.weight(.semibold))
				.padding(.top, 4)
		case .blockquote(let text):
			HStack(alignment: .top, spacing: 6) {
				Rectangle()
					.fill(theme.accentColor.color)
					.frame(width: 2)
				Text(text)
					.font(.body)
					.italic()
					.foregroundStyle(theme.secondaryTextColor.color)
			}
			.fixedSize(horizontal: false, vertical: true)
		case .list(let items, let ordered):
			VStack(alignment: .leading, spacing: 4) {
				// Blocks are immutable once parsed, so positional identity is stable here.
				ForEach(Array(items.enumerated()), id: \.offset) { index, item in
					HStack(alignment: .top, spacing: 4) {
						Text(ordered ? "\(index + 1)." : "•")
							.foregroundStyle(theme.secondaryTextColor.color)
						Text(item)
					}
					.font(.body)
				}
			}
		case .code(let code):
			Text(code)
				.font(.system(.footnote, design: .monospaced))
				.padding(6)
				.frame(maxWidth: .infinity, alignment: .leading)
				.background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
		case .image(let altText):
			// v1 skips inline images — placeholder glyph with alt text, per the design.
			HStack(spacing: 4) {
				Image(systemName: "photo")
				Text(altText.isEmpty ? "Image" : altText)
					.lineLimit(2)
			}
			.font(.caption2)
			.foregroundStyle(theme.secondaryTextColor.color)
		}
	}
}
