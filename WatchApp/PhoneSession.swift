//
//  PhoneSession.swift
//  NetNewsWire Watch App
//
//  Copyright © 2026 Ranchero Software. All rights reserved.
//

import Foundation
import WatchConnectivity
import os

// M1 scaffolding — see Technotes/WatchApp.md "Architecture overview" (relay path) and
// "Reading experience". This is the watch side of the phone's WatchBridge: it activates
// WCSession, receives article snapshot files, and sends queued status changes back.
//
// WCSessionDelegate calls arrive on a private background queue, not the main actor — every
// delegate requirement below is `nonisolated` and hops to the main actor explicitly rather
// than touching `store`/`statusQueue` (both main-actor types) directly.

/// Watch-side WatchConnectivity wrapper for the relay path. Direct-to-Miniflux sync (M2)
/// doesn't go through this type at all — it's a seam in `SyncCoordinator`, not here.
@MainActor
final class PhoneSession: NSObject {

	private(set) var isReachable = false

	/// Fired on the main actor when the phone transitions from unreachable to reachable —
	/// including when session activation completes with the phone in range. `SyncCoordinator`
	/// uses it to flush the queue and sync opportunistically, per the design's sync triggers.
	var onBecameReachable: (@MainActor () -> Void)?

	private let store: WatchStore
	private let statusQueue: StatusQueue
	private let directSyncSettings: DirectSyncSettings
	private let session: WCSession?

	// WCSessionDelegate callbacks arrive off the main actor; a nonisolated Logger (a plain
	// Sendable struct) can be logged to from those callbacks without an actor hop.
	private nonisolated let logger = Logger(subsystem: WatchLog.subsystem, category: "PhoneSession")

	/// Tracks in-flight `transferUserInfo` status-batch sends so `session(_:didFinish
	/// userInfoTransfer:error:)` can confirm delivery back to the `StatusQueue`.
	private var pendingUserInfoTransfers: [ObjectIdentifier: [WatchStatusChange]] = [:]

	init(store: WatchStore, statusQueue: StatusQueue, directSyncSettings: DirectSyncSettings) {
		self.store = store
		self.statusQueue = statusQueue
		self.directSyncSettings = directSyncSettings
		self.session = WCSession.isSupported() ? WCSession.default : nil
		super.init()
	}

	/// Activates the session. Safe to call once at app launch; WCSession delivers queued
	/// background transfers once a delegate is set and activation completes.
	func activate() {
		guard let session else {
			logger.notice("WatchConnectivity is not supported on this device")
			return
		}
		session.delegate = self
		session.activate()
	}

	/// Watch → phone: ask for a fresh article snapshot. Sent interactively when the phone is
	/// reachable, otherwise queued for opportunistic delivery.
	func requestSnapshot() {
		guard let session, session.activationState == .activated else {
			return
		}
		let message = WatchMessage.requestSnapshotMessage()
		if session.isReachable {
			session.sendMessage(message, replyHandler: nil) { [logger] error in
				logger.error("requestSnapshot send failed: \(error.localizedDescription)")
			}
		} else {
			session.transferUserInfo(message)
		}
	}

	/// Watch → phone: flush queued status changes. Confirmed sends are removed from the
	/// `StatusQueue`; failed or undeliverable sends are reset back to pending for retry.
	func sendStatusBatch(_ changes: [WatchStatusChange]) {
		guard !changes.isEmpty, let session, session.activationState == .activated else {
			if !changes.isEmpty {
				statusQueue.resetSelected(changes)
			}
			return
		}

		let message = WatchMessage.statusBatchMessage(WatchStatusBatch(changes: changes))

		if session.isReachable {
			session.sendMessage(message, replyHandler: { [weak self] _ in
				Task { @MainActor [weak self] in
					self?.statusQueue.deleteSelected(changes)
				}
			}, errorHandler: { [weak self, logger] error in
				logger.error("Status batch send failed: \(error.localizedDescription)")
				Task { @MainActor [weak self] in
					self?.statusQueue.resetSelected(changes)
				}
			})
		} else {
			let transfer = session.transferUserInfo(message)
			pendingUserInfoTransfers[ObjectIdentifier(transfer)] = changes
		}
	}
}

// MARK: - WCSessionDelegate

extension PhoneSession: WCSessionDelegate {

	nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
		if let error {
			logger.error("WCSession activation failed: \(error.localizedDescription)")
		}

		// WCSession persists the most recent application context across launches; a config
		// delivered while the app wasn't running is only visible here.
		let receivedContext = session.receivedApplicationContext
		if !receivedContext.isEmpty {
			let config = WatchAccountConfig.config(fromApplicationContext: receivedContext)
			Task { @MainActor [weak self] in
				self?.directSyncSettings.applyConfig(config)
			}
		}

		let reachable = session.isReachable
		Task { @MainActor [weak self] in
			self?.updateReachability(reachable)
		}
	}

	nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
		let reachable = session.isReachable
		Task { @MainActor [weak self] in
			self?.updateReachability(reachable)
		}
	}

	private func updateReachability(_ reachable: Bool) {
		let wasReachable = isReachable
		isReachable = reachable
		if reachable && !wasReachable {
			onBecameReachable?()
		}
	}

	/// Inbound dictionary payloads — status deltas and credentials can arrive both as
	/// interactive messages (phone reachable) and as queued `transferUserInfo` deliveries,
	/// so both delegate entry points funnel here. Parsing happens off the main actor (the
	/// dictionary isn't Sendable); the parsed values hop to the main actor to be applied.
	nonisolated private func handleIncoming(dictionary: [String: Any]) {
		if let batch = WatchMessage.statusBatch(from: dictionary) {
			Task { @MainActor [weak self] in
				self?.store.applyRemoteChanges(batch.changes)
			}
		} else if let credential = WatchCredential(dictionary: dictionary) {
			Task { @MainActor [weak self] in
				self?.directSyncSettings.storeCredential(credential)
			}
		} else if let accountID = WatchMessage.credentialTombstoneAccountID(from: dictionary) {
			Task { @MainActor [weak self] in
				self?.directSyncSettings.removeCredential(accountID: accountID)
			}
		} else {
			logger.debug("Dropping unrecognized payload from the phone")
		}
	}

	nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
		handleIncoming(dictionary: message)
	}

	nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
		handleIncoming(dictionary: userInfo)
	}

	/// The phone-forwarded account config for the direct sync path. Latest-wins; a context
	/// without a config means no Miniflux account exists on the phone anymore.
	nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
		let config = WatchAccountConfig.config(fromApplicationContext: applicationContext)
		Task { @MainActor [weak self] in
			self?.directSyncSettings.applyConfig(config)
		}
	}

	/// Snapshot files arrive here. The file must be copied out before this method returns —
	/// WatchConnectivity deletes it as soon as the delegate call completes — so the copy
	/// happens synchronously and the (potentially large) decode happens in a follow-up Task,
	/// off the main actor; only the final `store.applySnapshot` call hops back on.
	nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
		let destinationURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
		do {
			try FileManager.default.copyItem(at: file.fileURL, to: destinationURL)
		} catch {
			logger.error("Failed to copy received snapshot file: \(error.localizedDescription)")
			return
		}

		Task {
			defer { try? FileManager.default.removeItem(at: destinationURL) }
			do {
				let data = try Data(contentsOf: destinationURL)
				let snapshot = try WatchSnapshot.decode(from: data)
				await applyReceivedSnapshot(snapshot)
			} catch let WatchSchemaError.unsupportedVersion(version) {
				logger.notice("Ignoring snapshot with unsupported schema version \(version)")
			} catch {
				logger.error("Failed to decode received snapshot: \(error.localizedDescription)")
			}
		}
	}

	private func applyReceivedSnapshot(_ snapshot: WatchSnapshot) async {
		await store.applySnapshot(snapshot)
	}

	nonisolated func session(_ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: (any Error)?) {
		let transferID = ObjectIdentifier(userInfoTransfer)
		Task { @MainActor [weak self] in
			guard let self, let changes = self.pendingUserInfoTransfers.removeValue(forKey: transferID) else {
				return
			}
			if let error {
				self.logger.error("Status batch transfer failed: \(error.localizedDescription)")
				self.statusQueue.resetSelected(changes)
			} else {
				self.statusQueue.deleteSelected(changes)
			}
		}
	}
}
