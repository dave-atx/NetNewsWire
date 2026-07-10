//
//  AppCommands.swift
//  NetNewsWire-iOS
//
//  Copyright © 2026 Ranchero Software. All rights reserved.
//

import UIKit

@MainActor enum AppCommands {

	static func globalKeyCommands() -> [UIKeyCommand] {
		var keys = [UIKeyCommand]()

		keys.append(keyCommand(title: NSLocalizedString("Scroll or Go to Next Unread", comment: "Command"), action: "scrollOrGoToNextUnread:", input: "\u{0020}"))
		keys.append(keyCommand(title: NSLocalizedString("Scroll Up", comment: "Command"), action: "scrollUp:", input: "\u{0020}", modifiers: [.shift]))
		keys.append(keyCommand(title: NSLocalizedString("Go to Previous Unread", comment: "Command"), action: "goToPreviousUnread:", input: "-"))
		keys.append(keyCommand(action: "nextUnread:", input: "+"))
		keys.append(keyCommand(action: "nextUnread:", input: "+", modifiers: [.shift]))
		keys.append(keyCommand(title: NSLocalizedString("Next Unread", comment: "Command"), action: "nextUnread:", input: "n"))
		keys.append(keyCommand(title: NSLocalizedString("Mark Read", comment: "Command"), action: "toggleRead:", input: "r"))
		keys.append(keyCommand(title: NSLocalizedString("Mark Unread", comment: "Command"), action: "toggleRead:", input: "u"))
		keys.append(keyCommand(title: NSLocalizedString("Mark All as Read", comment: "Command"), action: "markAllAsRead:", input: "k"))
		keys.append(keyCommand(title: NSLocalizedString("Mark Unread and Go To Next Unread", comment: "Command"), action: "markUnreadAndGoToNextUnread:", input: "m"))
		keys.append(keyCommand(title: NSLocalizedString("Mark All as Read in Timeline and Go To Next Unread", comment: "Command"), action: "markAllAsReadAndGoToNextUnread:", input: "l"))
		keys.append(keyCommand(title: NSLocalizedString("Mark Older as Read", comment: "Command"), action: "markOlderArticlesAsRead:", input: "o"))
		keys.append(keyCommand(title: NSLocalizedString("Open in Browser", comment: "Command"), action: "openInBrowser:", input: "b"))
		keys.append(keyCommand(title: NSLocalizedString("Open In App Browser", comment: "Command"), action: "openInAppBrowser:", input: "\r"))
		keys.append(keyCommand(action: "openInBrowserUsingOppositeOfSettings:", input: "\r", modifiers: [.shift]))
		keys.append(keyCommand(action: "openInBrowserUsingOppositeOfSettings:", input: "b", modifiers: [.shift]))
		keys.append(keyCommand(title: NSLocalizedString("Go to Previous Feed", comment: "Command"), action: "goToPreviousSubscription:", input: "a"))
		keys.append(keyCommand(title: NSLocalizedString("Go to Next Feed", comment: "Command"), action: "goToNextSubscription:", input: "z"))
		keys.append(keyCommand(action: "toggleStarred:", input: "s"))
		keys.append(keyCommand(title: NSLocalizedString("Go To Settings", comment: "Command"), action: "goToSettings:", input: ",", modifiers: [.command]))

		return keys
	}

	static func sidebarKeyCommands() -> [UIKeyCommand] {
		var keys = [UIKeyCommand]()

		keys.append(keyCommand(title: NSLocalizedString("Select Next Up", comment: "Command"), action: "selectNextUp:", input: UIKeyCommand.inputUpArrow))
		keys.append(keyCommand(title: NSLocalizedString("Select Next Down", comment: "Command"), action: "selectNextDown:", input: UIKeyCommand.inputDownArrow))
		keys.append(keyCommand(action: "navigateToTimeline:", input: "\t"))
		keys.append(keyCommand(title: NSLocalizedString("Navigate to Timeline", comment: "Command"), action: "navigateToTimeline:", input: UIKeyCommand.inputRightArrow))
		keys.append(keyCommand(title: NSLocalizedString("Collapse Selected Row", comment: "Command"), action: "collapseSelectedRows:", input: ","))
		keys.append(keyCommand(title: NSLocalizedString("Collapse Selected Row", comment: "Command"), action: "collapseSelectedRows:", input: UIKeyCommand.inputLeftArrow, modifiers: [.command]))
		keys.append(keyCommand(title: NSLocalizedString("Expand Selected Row", comment: "Command"), action: "expandSelectedRows:", input: "."))
		keys.append(keyCommand(title: NSLocalizedString("Expand Selected Row", comment: "Command"), action: "expandSelectedRows:", input: UIKeyCommand.inputRightArrow, modifiers: [.command]))
		keys.append(keyCommand(title: NSLocalizedString("Collapse All", comment: "Command"), action: "collapseAllExceptForGroupItems:", input: ";"))
		keys.append(keyCommand(action: "collapseAllExceptForGroupItems:", input: UIKeyCommand.inputLeftArrow, modifiers: [.command, .alternate]))
		keys.append(keyCommand(title: NSLocalizedString("Expand All", comment: "Command"), action: "expandAll:", input: "'"))
		keys.append(keyCommand(action: "expandAll:", input: UIKeyCommand.inputRightArrow, modifiers: [.command, .alternate]))
		keys.append(keyCommand(title: NSLocalizedString("Delete", comment: "Command"), action: "delete:", input: "\u{8}"))

		return keys
	}

	static func timelineKeyCommands() -> [UIKeyCommand] {
		var keys = [UIKeyCommand]()

		keys.append(keyCommand(title: NSLocalizedString("Select Next Up", comment: "Command"), action: "selectNextUp:", input: UIKeyCommand.inputUpArrow))
		keys.append(keyCommand(title: NSLocalizedString("Select Next Down", comment: "Command"), action: "selectNextDown:", input: UIKeyCommand.inputDownArrow))
		keys.append(keyCommand(title: NSLocalizedString("Navigate to Feeds", comment: "Command"), action: "navigateToSidebar:", input: UIKeyCommand.inputLeftArrow))
		keys.append(keyCommand(title: NSLocalizedString("Navigate to Detail", comment: "Command"), action: "navigateToDetail:", input: UIKeyCommand.inputRightArrow))

		return keys
	}

	static func detailKeyCommands() -> [UIKeyCommand] {
		var keys = [UIKeyCommand]()

		keys.append(keyCommand(title: NSLocalizedString("Navigate to Timeline", comment: "Command"), action: "navigateToTimeline:", input: UIKeyCommand.inputLeftArrow))

		return keys
	}

	static func buildMenus(with builder: UIMenuBuilder) {
		fileMenu(builder)
		findMenu(builder)
		let hasViewMenu = builder.menu(for: .view) != nil
		viewMenu(builder, hasViewMenu: hasViewMenu)
		goMenu(builder, hasViewMenu: hasViewMenu)
		articleMenu(builder)
	}
}

private extension AppCommands {

	static let newItemsMenuIdentifier = UIMenu.Identifier(rawValue: "com.ranchero.NetNewsWire.newItems")
	static let findMenuIdentifier = UIMenu.Identifier(rawValue: "com.ranchero.NetNewsWire.find")
	static let sortByMenuIdentifier = UIMenu.Identifier(rawValue: "com.ranchero.NetNewsWire.sortBy")
	static let viewMenuIdentifier = UIMenu.Identifier(rawValue: "com.ranchero.NetNewsWire.view")
	static let goMenuIdentifier = UIMenu.Identifier(rawValue: "com.ranchero.NetNewsWire.go")
	static let articleMenuIdentifier = UIMenu.Identifier(rawValue: "com.ranchero.NetNewsWire.article")

	static func keyCommand(title: String? = nil, action: String, input: String, modifiers: UIKeyModifierFlags = []) -> UIKeyCommand {
		let selector = NSSelectorFromString(action)
		let command: UIKeyCommand
		if let title {
			command = UIKeyCommand(title: title, action: selector, input: input, modifierFlags: modifiers)
		} else {
			command = UIKeyCommand(input: input, modifierFlags: modifiers, action: selector)
		}
		command.wantsPriorityOverSystemBehavior = true
		return command
	}

	static func menuCommand(title: String, action: String, input: String? = nil, modifiers: UIKeyModifierFlags = []) -> UIMenuElement {
		guard let input else {
			return UICommand(title: title, action: NSSelectorFromString(action))
		}
		let command = UIKeyCommand(title: title, action: NSSelectorFromString(action), input: input, modifierFlags: modifiers)
		command.wantsPriorityOverSystemBehavior = true
		return command
	}

	// MARK: - File

	static func fileMenu(_ builder: UIMenuBuilder) {
		let importExportGroup = UIMenu(title: "", options: .displayInline, children: [
			menuCommand(title: NSLocalizedString("Import Subscriptions…", comment: "Command"), action: "importOPML:"),
			menuCommand(title: NSLocalizedString("Export Subscriptions…", comment: "Command"), action: "exportOPML:", input: "e", modifiers: [.command, .alternate])
		])
		builder.insertChild(importExportGroup, atStartOfMenu: .file)

		let refreshGroup = UIMenu(title: "", options: .displayInline, children: [
			menuCommand(title: NSLocalizedString("Refresh", comment: "Command"), action: "refresh:", input: "r", modifiers: [.command])
		])
		builder.insertChild(refreshGroup, atStartOfMenu: .file)

		let newItemsGroup = UIMenu(title: "", image: nil, identifier: newItemsMenuIdentifier, options: .displayInline, children: [
			menuCommand(title: NSLocalizedString("New Feed", comment: "Command"), action: "addNewFeed:", input: "n", modifiers: [.command]),
			menuCommand(title: NSLocalizedString("New Folder", comment: "Command"), action: "addNewFolder:", input: "n", modifiers: [.command, .shift])
		])
		builder.insertChild(newItemsGroup, atStartOfMenu: .file)
	}

	// MARK: - Find

	static func findMenu(_ builder: UIMenuBuilder) {
		let findElements = [
			menuCommand(title: NSLocalizedString("Article Search", comment: "Command"), action: "articleSearch:", input: "f", modifiers: [.command, .alternate]),
			menuCommand(title: NSLocalizedString("Find in Article", comment: "Command"), action: "beginFind:", input: "f", modifiers: [.command])
		]

		if builder.menu(for: .find) != nil {
			let findGroup = UIMenu(title: "", options: .displayInline, children: findElements)
			builder.insertChild(findGroup, atStartOfMenu: .find)
		} else {
			let findMenu = UIMenu(title: NSLocalizedString("Find", comment: "Command"), identifier: findMenuIdentifier, children: findElements)
			builder.insertChild(findMenu, atEndOfMenu: .edit)
		}
	}

	// MARK: - View

	static func viewMenu(_ builder: UIMenuBuilder, hasViewMenu: Bool) {
		let sortByMenu = UIMenu(title: NSLocalizedString("Sort Articles By", comment: "Command"), identifier: sortByMenuIdentifier, children: [
			menuCommand(title: NSLocalizedString("Newest Article on Top", comment: "Command"), action: "sortByNewestArticleOnTop:"),
			menuCommand(title: NSLocalizedString("Oldest Article on Top", comment: "Command"), action: "sortByOldestArticleOnTop:")
		])
		let groupByFeedCommand = menuCommand(title: NSLocalizedString("Group by Feed", comment: "Command"), action: "groupByFeedToggled:")
		let topGroup = UIMenu(title: "", options: .displayInline, children: [sortByMenu, groupByFeedCommand])

		let cleanUpGroup = UIMenu(title: "", options: .displayInline, children: [
			menuCommand(title: NSLocalizedString("Clean Up", comment: "Command"), action: "cleanUp:", input: "'", modifiers: [.command]),
			menuCommand(title: NSLocalizedString("Hide Read Articles", comment: "Command"), action: "toggleReadArticlesFilter:", input: "h", modifiers: [.command, .shift]),
			menuCommand(title: NSLocalizedString("Hide Read Feeds", comment: "Command"), action: "toggleReadFeedsFilter:", input: "f", modifiers: [.command, .shift])
		])

		let toggleSidebarGroup = UIMenu(title: "", options: .displayInline, children: [
			menuCommand(title: NSLocalizedString("Toggle Sidebar", comment: "Command"), action: "toggleSidebar:", input: "s", modifiers: [.command, .control])
		])

		if hasViewMenu {
			builder.insertChild(toggleSidebarGroup, atStartOfMenu: .view)
			builder.insertChild(cleanUpGroup, atStartOfMenu: .view)
			builder.insertChild(topGroup, atStartOfMenu: .view)
		} else {
			let viewMenu = UIMenu(title: NSLocalizedString("View", comment: "Command"), identifier: viewMenuIdentifier, children: [topGroup, cleanUpGroup, toggleSidebarGroup])
			builder.insertSibling(viewMenu, afterMenu: .edit)
		}
	}

	// MARK: - Go

	static func goMenu(_ builder: UIMenuBuilder, hasViewMenu: Bool) {
		let nextUnreadCommand = menuCommand(title: NSLocalizedString("Next Unread", comment: "Command"), action: "nextUnread:", input: "/", modifiers: [.command])
		let smartFeedsGroup = UIMenu(title: "", options: .displayInline, children: [
			menuCommand(title: NSLocalizedString("Today", comment: "Command"), action: "goToToday:", input: "1", modifiers: [.command]),
			menuCommand(title: NSLocalizedString("All Unread", comment: "Command"), action: "goToAllUnread:", input: "2", modifiers: [.command]),
			menuCommand(title: NSLocalizedString("Starred", comment: "Command"), action: "goToStarred:", input: "3", modifiers: [.command])
		])

		let goMenu = UIMenu(title: NSLocalizedString("Go", comment: "Command"), identifier: goMenuIdentifier, children: [nextUnreadCommand, smartFeedsGroup])

		if hasViewMenu {
			builder.insertSibling(goMenu, afterMenu: .view)
		} else {
			builder.insertSibling(goMenu, afterMenu: .edit)
		}
	}

	// MARK: - Article

	static func articleMenu(_ builder: UIMenuBuilder) {
		let markGroup = UIMenu(title: "", options: .displayInline, children: [
			menuCommand(title: NSLocalizedString("Mark as Read", comment: "Command"), action: "toggleRead:", input: "u", modifiers: [.command, .shift]),
			menuCommand(title: NSLocalizedString("Mark All as Read", comment: "Command"), action: "markAllAsRead:", input: "k", modifiers: [.command]),
			menuCommand(title: NSLocalizedString("Mark Above as Read", comment: "Command"), action: "markAboveAsRead:", input: "k", modifiers: [.command, .control]),
			menuCommand(title: NSLocalizedString("Mark Below as Read", comment: "Command"), action: "markBelowAsRead:", input: "k", modifiers: [.command, .shift])
		])

		let starredGroup = UIMenu(title: "", options: .displayInline, children: [
			menuCommand(title: NSLocalizedString("Mark as Starred", comment: "Command"), action: "toggleStarred:", input: "l", modifiers: [.command, .shift])
		])

		let readerGroup = UIMenu(title: "", options: .displayInline, children: [
			menuCommand(title: NSLocalizedString("Show Reader View", comment: "Command"), action: "toggleReaderView:", input: "r", modifiers: [.command, .shift]),
			menuCommand(title: NSLocalizedString("Open in Browser", comment: "Command"), action: "openInBrowser:", input: UIKeyCommand.inputRightArrow, modifiers: [.command]),
			menuCommand(title: NSLocalizedString("Get Feed Info", comment: "Command"), action: "showFeedInspector:", input: "i", modifiers: [.command])
		])

		let articleMenu = UIMenu(title: NSLocalizedString("Article", comment: "Command"), identifier: articleMenuIdentifier, children: [markGroup, starredGroup, readerGroup])
		builder.insertSibling(articleMenu, afterMenu: goMenuIdentifier)
	}
}
