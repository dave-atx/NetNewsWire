//
//  DetailContainerView.swift
//  NetNewsWire
//
//  Created by Brent Simmons on 2/12/19.
//  Copyright © 2019 Ranchero Software. All rights reserved.
//

import AppKit

final class DetailContainerView: NSView, @MainActor NSTextFinderBarContainer {

	@IBOutlet var linkOverlayView: DetailLinkOverlayView!

	var contentViewConstraints: [NSLayoutConstraint]?

	var contentView: NSView? {
		didSet {
			if contentView == oldValue {
				return
			}

			if let currentConstraints = contentViewConstraints {
				NSLayoutConstraint.deactivate(currentConstraints)
			}
			contentViewConstraints = nil
			oldValue?.removeFromSuperviewWithoutNeedingDisplay()

			if let contentView = contentView {
				contentView.translatesAutoresizingMaskIntoConstraints = false
				addSubview(contentView, positioned: .below, relativeTo: linkOverlayView)
				// Leading and trailing follow the safe area so the article view doesn’t extend under the sidebar
				// in column layout on macOS 26. Top stays at the edge: the web view handles the toolbar itself.
				let constraints = [
					contentViewTopConstraint(contentView),
					contentView.bottomAnchor.constraint(equalTo: bottomAnchor),
					contentView.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
					contentView.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor)
				]
				NSLayoutConstraint.activate(constraints)
				contentViewConstraints = constraints
			}
		}
	}

	private func contentViewTopConstraint(_ contentView: NSView) -> NSLayoutConstraint {
		if isFindBarVisible {
			return contentView.topAnchor.constraint(equalTo: findBarContainerView.bottomAnchor)
		}
		return contentView.topAnchor.constraint(equalTo: topAnchor)
	}

	private func updateContentViewTopConstraint() {
		guard let contentView, var constraints = contentViewConstraints, let index = constraints.firstIndex(where: { $0.firstAttribute == .top }) else {
			return
		}
		constraints[index].isActive = false
		constraints[index] = contentViewTopConstraint(contentView)
		constraints[index].isActive = true
		contentViewConstraints = constraints
	}

	override func draw(_ dirtyRect: NSRect) {
		NSColor.controlBackgroundColor.set()
		let r = dirtyRect.intersection(bounds)
		r.fill()
	}

	// MARK: NSTextFinderBarContainer

	@IBOutlet var findBarContainerView: NSView!
	@IBOutlet var findBarHeightConstraint: NSLayoutConstraint!


	public var findBarView: NSView? = nil {
		didSet {
			oldValue?.removeFromSuperview()
		}
	}

	public var isFindBarVisible = false {
		didSet {
			// It seems AppKit assumes the findBarView will be removed from its superview when it's
			// not being shown, so we have to fulfill that expectation in addition to hiding the stack view
			// container we embed it in.
			if
				self.isFindBarVisible,
				let view = findBarView
			{
				view.layoutSubtreeIfNeeded()
				view.frame.origin = NSZeroPoint
				view.frame.size.width = self.findBarContainerView.bounds.width
				findBarContainerView.frame = view.bounds
				findBarHeightConstraint.constant = view.frame.size.height + 1.0
				findBarContainerView.addSubview(view)
			}
			else {
				if let view = findBarView {
					view.removeFromSuperview()
					findBarHeightConstraint.constant = 0
				}
			}

			// The web view sits below the find bar while it’s visible.
			updateContentViewTopConstraint()
		}
	}

	func findBarViewDidChangeHeight() {
		if let height = findBarView?.frame.size.height {
			findBarHeightConstraint.constant = height + 1.0
			findBarContainerView.layoutSubtreeIfNeeded()
			findBarView?.setFrameOrigin(NSPoint.zero)
		}
	}

}
