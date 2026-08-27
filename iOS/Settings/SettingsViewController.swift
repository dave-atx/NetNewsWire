//
//  SettingsViewController.swift
//  NetNewsWire-iOS
//
//  Created by Maurice Parker on 4/24/19.
//  Copyright © 2019 Ranchero Software. All rights reserved.
//

import UIKit
import CoreServices
import SafariServices
import SwiftUI
import RSCore
import Account
import ActivityLog

final class SettingsViewController: UITableViewController {

	private enum Section: Int {
		case notifications = 0
		case accounts = 1
		case feeds = 2
		case moreScreens = 3
		case troubleshooting = 4
		case help = 5
	}

	private enum MoreScreensRow: Int {
		case appearance = 0
		case sidebar = 1
		case timeline = 2
		case articles = 3
	}

	private enum TroubleshootingRow: Int {
		case errorLog = 0
		case activityLog = 1
		case accountStats = 2
		case dinosaurs = 3
		case cloudKitZoneStats = 4
	}

	private enum HelpRow: Int {
		case help = 0
		case forum = 1
		case releaseNotes = 2
		case bugTracker = 3
		case about = 4
	}

	private enum FeedsRow: Int {
		case importSubscriptions = 0
		case exportSubscriptions = 1
		case addNetNewsWireNewsFeed = 2
	}

	private lazy var opmlController = OPMLImportExportController(presentingViewController: self)

	/// Pushes the Timeline screen on appearing, so a user can turn off the Mark All as Read confirmation.
	var showTimelineSettings = false
	weak var presentingParentController: UIViewController?

	override func viewDidLoad() {
		// This hack mostly works around a bug in static tables with dynamic type.  See: https://spin.atomicobject.com/2018/10/15/dynamic-type-static-uitableview/
		NotificationCenter.default.removeObserver(tableView!, name: UIContentSizeCategory.didChangeNotification, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(contentSizeCategoryDidChange), name: UIContentSizeCategory.didChangeNotification, object: nil)

		NotificationCenter.default.addObserver(self, selector: #selector(accountsDidChange), name: .UserDidAddAccount, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(accountsDidChange), name: .UserDidDeleteAccount, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(displayNameDidChange), name: .DisplayNameDidChange, object: nil)

		tableView.register(UINib(nibName: "SettingsComboTableViewCell", bundle: nil), forCellReuseIdentifier: "SettingsComboTableViewCell")
		tableView.register(UINib(nibName: "SettingsTableViewCell", bundle: nil), forCellReuseIdentifier: "SettingsTableViewCell")

		tableView.rowHeight = UITableView.automaticDimension
		tableView.estimatedRowHeight = 44
	}

	override func viewWillAppear(_ animated: Bool) {
		super.viewWillAppear(animated)

		let buildLabel = CopyableLabel(frame: CGRect(x: 32.0, y: 0.0, width: 0.0, height: 0.0))
		buildLabel.font = UIFont.systemFont(ofSize: 11.0)
		buildLabel.textColor = UIColor.gray
		buildLabel.text = "\(Bundle.main.appName) \(Bundle.main.versionNumber) (build \(Bundle.main.buildNumber))"
		buildLabel.sizeToFit()

		let wrapperView = UIView(frame: CGRect(x: 0, y: 0, width: tableView.bounds.width, height: buildLabel.frame.height + 10.0))
		wrapperView.addSubview(buildLabel)
		tableView.tableFooterView = wrapperView
	}

	override func viewDidAppear(_ animated: Bool) {
		super.viewDidAppear(animated)
		self.tableView.selectRow(at: nil, animated: true, scrollPosition: .none)

		if showTimelineSettings {
			showTimelineSettings = false
			navigationController?.pushViewController(TimelineSettingsViewController(), animated: true)
		}
	}

	// MARK: UITableView

	override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {

		switch Section(rawValue: section) {
		case .accounts:
			return AccountManager.shared.accounts.count + 1
		case .feeds:
			let defaultNumberOfRows = super.tableView(tableView, numberOfRowsInSection: section)
			if AccountManager.shared.activeAccounts.isEmpty || AccountManager.shared.anyAccountHasNetNewsWireNewsSubscription() {
				return defaultNumberOfRows - 1
			}
			return defaultNumberOfRows
		case .troubleshooting:
			let defaultNumberOfRows = super.tableView(tableView, numberOfRowsInSection: section)
			if !AccountManager.shared.hasiCloudAccount {
				return defaultNumberOfRows - 1
			}
			return defaultNumberOfRows
		default:
			return super.tableView(tableView, numberOfRowsInSection: section)
		}
	}

	override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {

		let cell: UITableViewCell
		switch Section(rawValue: indexPath.section) {
		case .accounts:

			let sortedAccounts = AccountManager.shared.sortedAccounts
			if indexPath.row == sortedAccounts.count {
				cell = tableView.dequeueReusableCell(withIdentifier: "SettingsTableViewCell", for: indexPath)
				cell.textLabel?.text = NSLocalizedString("Add Account", comment: "Add Account")
			} else {
				let acctCell = tableView.dequeueReusableCell(withIdentifier: "SettingsComboTableViewCell", for: indexPath) as! SettingsComboTableViewCell
				acctCell.applyThemeProperties()
				let account = sortedAccounts[indexPath.row]
				acctCell.comboImage?.image = Assets.accountImage(account.type)
				acctCell.comboNameLabel?.text = account.nameForDisplay
				cell = acctCell
			}
		default:
			cell = super.tableView(tableView, cellForRowAt: indexPath)

		}

		return cell
	}

	override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {

		switch Section(rawValue: indexPath.section) {
		case .notifications:
			UIApplication.shared.open(URL(string: "\(UIApplication.openSettingsURLString)")!)
			tableView.selectRow(at: nil, animated: true, scrollPosition: .none)
		case .accounts:
			let sortedAccounts = AccountManager.shared.sortedAccounts
			if indexPath.row == sortedAccounts.count {
				let addAccountView = AddAccountView(presentationAnchor: view.window) { [weak self] in
					self?.navigationController?.popViewController(animated: false)
				}
				self.navigationController?.pushViewController(UIHostingController(rootView: addAccountView), animated: true)
			} else {
				let controller = UIStoryboard.inspector.instantiateController(ofType: AccountInspectorViewController.self)
				controller.account = sortedAccounts[indexPath.row]
				self.navigationController?.pushViewController(controller, animated: true)
			}
		case .feeds:
			switch FeedsRow(rawValue: indexPath.row) {
			case .importSubscriptions:
				tableView.selectRow(at: nil, animated: true, scrollPosition: .none)
				opmlController.importOPML(sourceRect: tableView.rectForRow(at: indexPath))
			case .exportSubscriptions:
				tableView.selectRow(at: nil, animated: true, scrollPosition: .none)
				opmlController.exportOPML(sourceRect: tableView.rectForRow(at: indexPath))
			case .addNetNewsWireNewsFeed:
				addFeed()
				tableView.selectRow(at: nil, animated: true, scrollPosition: .none)
			default:
				break
			}
		case .moreScreens:
			switch MoreScreensRow(rawValue: indexPath.row) {
			case .sidebar:
				self.navigationController?.pushViewController(SidebarSettingsViewController(), animated: true)
			case .timeline:
				self.navigationController?.pushViewController(TimelineSettingsViewController(), animated: true)
			case .articles:
				self.navigationController?.pushViewController(ArticlesSettingsViewController(), animated: true)
			case .appearance:
				self.navigationController?.pushViewController(GeneralSettingsViewController(), animated: true)
			default:
				break
			}
		case .troubleshooting:
			let viewController: UIViewController? = {
				switch TroubleshootingRow(rawValue: indexPath.row) {
				case .errorLog:
					return UIHostingController(rootView: ErrorLogView())
				case .accountStats:
					return UIHostingController(rootView: AccountStatsView())
				case .cloudKitZoneStats:
					return UIHostingController(rootView: CloudKitStatsView())
				case .activityLog:
					return UIHostingController(rootView: ActivityLogView())
				case .dinosaurs:
					return UIHostingController(rootView: DinosaursView(dismissAndPresent: { [weak self] dinosaur in
						guard let self else {
							return
						}
						self.dismiss(animated: true) {
							if let rootSplit = self.presentingParentController as? RootSplitViewController {
								rootSplit.coordinator.discloseFeed(dinosaur.feed, animations: [.scroll, .navigation])
							}
						}
					}))
				default:
					return nil
				}
			}()
			if let viewController {
				self.navigationController?.pushViewController(viewController, animated: true)
			}
		case .help:
			switch HelpRow(rawValue: indexPath.row) {
			case .help:
				openURL(HelpURL.helpHome.rawValue)
				tableView.selectRow(at: nil, animated: true, scrollPosition: .none)
			case .forum:
				openURL(HelpURL.discourse.rawValue)
				tableView.selectRow(at: nil, animated: true, scrollPosition: .none)
			case .releaseNotes:
				openURL(HelpURL.releaseNotes.rawValue)
				tableView.selectRow(at: nil, animated: true, scrollPosition: .none)
			case .bugTracker:
				openURL(HelpURL.bugTracker.rawValue)
				tableView.selectRow(at: nil, animated: true, scrollPosition: .none)
			case .about:
				let hosting = UIHostingController(rootView: AboutView())
				self.navigationController?.pushViewController(hosting, animated: true)
			default:
				break
			}
		default:
			tableView.selectRow(at: nil, animated: true, scrollPosition: .none)
		}
	}

	override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
		return false
	}

	override func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
		return false
	}

	override func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle {
		return .none
	}

	override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
		return UITableView.automaticDimension
	}

	override func tableView(_ tableView: UITableView, indentationLevelForRowAt indexPath: IndexPath) -> Int {
		return super.tableView(tableView, indentationLevelForRowAt: IndexPath(row: 0, section: Section.accounts.rawValue))
	}

	// MARK: Actions

	@IBAction func done(_ sender: Any) {
		dismiss(animated: true)
	}

	// MARK: - Notifications

	@objc func contentSizeCategoryDidChange() {
		tableView.reloadData()
	}

	@objc func accountsDidChange() {
		tableView.reloadData()
	}

	@objc func displayNameDidChange() {
		tableView.reloadData()
	}

	@objc func browserPreferenceDidChange() {
		tableView.reloadData()
	}

}

// MARK: - Private

private extension SettingsViewController {

	func addFeed() {
		self.dismiss(animated: true)

		let addFeedView = AddFeedView(initialFeed: AccountManager.netNewsWireNewsURL, initialFeedName: NSLocalizedString("NetNewsWire News", comment: "NetNewsWire News"))
		let hostingController = UIHostingController(rootView: addFeedView)
		hostingController.modalPresentationStyle = .formSheet
		hostingController.preferredContentSize = UIViewController.formSheetSize

		presentingParentController?.present(hostingController, animated: true)
	}

	func openURL(_ urlString: String) {
		guard let url = URL(string: urlString) else {
			return
		}

		// Open GitHub links in the GitHub app when installed.
		if let host = url.host, host == "github.com" || host.hasSuffix(".github.com") {
			UIApplication.shared.open(url, options: [.universalLinksOnly: true]) { [weak self] openedInApp in
				if !openedInApp {
					self?.presentSafariViewController(for: url)
				}
			}
			return
		}

		presentSafariViewController(for: url)
	}

	private func presentSafariViewController(for url: URL) {
		let vc = SFSafariViewController(url: url)
		vc.modalPresentationStyle = .pageSheet
		present(vc, animated: true)
	}
}
