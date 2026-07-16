# NetNewsWire for Apple Watch — Design

Status: design approved by Dave 2026-07-16. Nothing implemented yet — next step is M1.

## Handoff context (for the implementing agent)

- Branch `watch-app` is based on `miniflux-api` (not yet merged to `main`), which adds the native Miniflux account type this design reuses. Don't rebase onto `main`; Miniflux support only exists here.
- Product decisions already made by Dave — don't re-ask:
  - Sync: phone relay when reachable + direct Miniflux sync when not (his primary use case is traveling with WiFi-only, away from the phone).
  - Cache: recent unread (~200) + all starred.
  - Save-for-later = starring. No new concept.
  - Article view renders feed-provided content only — no Mercury/extraction pass in v1. (watchOS has no Safari reader API; that option was already ruled out.)
  - Theme support: built-in native watch themes first; deriving colors from installed `.nnwtheme` files is a later exploration (v1.5), not v1.
- Work milestone by milestone (M1 first) as ordered below. For rote implementation work, Dave wants Sonnet low-effort subagents; exploration on Haiku/Sonnet low effort.
- This design was written on a Linux box with no Xcode — nothing has been built. Before adding watch code, verify the repo still builds on macOS as-is (`./buildscripts/build_and_test.sh` or the xcodebuild commands in CLAUDE.md).
- Facts verified by codebase exploration (trust these; file paths checked 2026-07-16): no watchOS target exists in the project; `MinifluxAPICaller` + `Miniflux*` models are Foundation/RSWeb/Secrets-only; no module's `Package.swift` declares watchOS in `platforms:`; `CredentialsManager` derives its keychain access group from the `AppGroup` Info.plist key; `NSAttributedString(simpleHTML:)` in `Shared/Extensions/NSAttributedString+Extensions.swift` is the existing non-WebKit HTML converter to extend.

## Goals

The watch app exists for one scenario: the user is away from their iPhone — traveling, sometimes with WiFi, often with nothing — and wants to read articles and triage their feeds from the watch alone.

1. **Standalone reading.** Read cached articles on the watch with no phone and no network.
2. **Standalone sync over WiFi.** When the watch has WiFi (or LTE) and the phone is unreachable, sync directly with the Miniflux server: pull fresh articles, push queued read/star changes.
3. **Phone relay when available.** When the phone is nearby, sync through it via WatchConnectivity — this works for *any* account type on the phone, not just Miniflux.
4. **Offline queueing.** Read and star actions taken offline are queued durably and flushed opportunistically, in either direction.
5. **Save for later = star.** Starring is the sync-backed save mechanism; no new concept.

Non-goals (v1): feed management, article search, full-text extraction (reader view renders feed-provided content only), inline images beyond a lead thumbnail, macOS involvement.

## Architecture overview

```
┌────────────────────────┐          ┌─────────────────────────┐
│ iPhone app             │          │ Watch app (SwiftUI)     │
│                        │  WC      │                         │
│ WatchBridge ───────────┼──────────┼─ PhoneSession           │
│  (snapshots out,       │          │      │                  │
│   statuses in)         │          │  SyncCoordinator        │
│        │               │          │   │          │          │
│  Account/SyncDatabase  │          │ WatchStore  StatusQueue │
└────────┬───────────────┘          │   │          │          │
         │                          │ MinifluxAPI (direct)    │
         ▼                          └──────┬──────────────────┘
   Miniflux / Feedbin / …                  │  HTTPS (WiFi/LTE)
         ▲                                 │
         └────────── Miniflux only ────────┘
```

Two sync paths, one queue:

- **Relay path (preferred when phone reachable).** The phone assembles an *article snapshot* (see Cache policy) and ships it via WatchConnectivity. Watch status changes go back as small messages; the phone applies them through the normal `Account.markArticles` flow, so they enter the existing `SyncDatabase` queue and reach whatever service the account uses.
- **Direct path (phone unreachable, network available, Miniflux account).** The watch talks to the Miniflux server itself using the same API client the iOS app uses, pulling recent unread + starred entries and flushing its own status queue.

The watch never has two sources of truth: `SyncCoordinator` picks a path per sync attempt (phone reachable → relay; else direct if Miniflux credentials present and network up; else no-op) and both paths write into the same `WatchStore` and drain the same `StatusQueue`.

### Conflict rule

Same as `MinifluxAccountDelegate.applyEntryStatuses`: locally pending (unsent) status changes always win over incoming server/phone state. When applying a snapshot or server response, subtract article IDs that have pending queue entries before overwriting read/star flags.

## Code reuse and new modules

### New SPM package: `MinifluxAPI`

Extract from `Modules/Account/Sources/Account/Miniflux/`:

- `MinifluxAPICaller.swift`, `MinifluxEntry.swift`, `MinifluxFeed.swift`, `MinifluxCategory.swift`, `MinifluxUser.swift`, `MinifluxVersion.swift`, `MinifluxError.swift`

These are Foundation + RSWeb + Secrets only — no UIKit/AppKit. The `Account` package then depends on `MinifluxAPI`; `MinifluxAccountDelegate` stays in `Account` and keeps orchestrating. This is a pure move, verified by building the existing targets before any watch code lands.

### Platform additions

Add `.watchOS(.v10)` to `platforms:` in `Package.swift` for: `Secrets`, `RSWeb`, `RSCore`, `RSParser` (for HTML entity decoding), and the new `MinifluxAPI`. Audit for watch-unavailable API at compile time; the keychain APIs `CredentialsManager` uses are watchOS-safe.

Deliberately **not** ported to watchOS: `Account`, `ArticlesDatabase`, `SyncDatabase`, `RSDatabase`. The watch store is small enough that pulling in FMDB/SQLite machinery is unjustified weight.

### New targets

- `NetNewsWire Watch App` — single-target watchOS app (SwiftUI), embedded in `NetNewsWire-iOS`. Own Info.plist + entitlements, joins the existing App Group (`$(APP_GROUP_ID)`) following the Widget/Intents/Share extension precedent. Note: the watch has its *own* keychain — app-group keychain sharing does not span devices; credentials arrive via WatchConnectivity (below).
- Shared watch-adjacent code that the iOS app needs (snapshot model, WC message schema) lives in `Shared/Watch/`, compiled into both the iOS and watch targets.

## Watch-side storage

No SQLite. Two Codable stores in the watch app's container, written atomically:

- **`WatchStore`** — the article cache. `WatchArticle`: `articleID`, `minifluxEntryID?`, `feedName`, `title`, `contentHTML` (feed-provided body, pre-trimmed), `textPreview` (first ~200 chars plain text, for rows), `datePublished`, `url`, `read`, `starred`. Capped per cache policy; JSON file (or one file per article if snapshot transfer favors it).
- **`StatusQueue`** — mirror of the `SyncStatus` shape: `(articleID, minifluxEntryID?, key: read|starred, flag, attemptState)`. Same selected-for-processing semantics as `SyncDatabase`: mark in-flight, delete on confirmed send, reset on failure. Persisted so a terminated app loses nothing.

`minifluxEntryID` is carried alongside NNW's `articleID` so the direct path can address Miniflux entries without a lookup table.

## Cache policy

"Recent unread + starred": newest **200 unread** articles (across all feeds, by `datePublished`) plus **all starred** (capped at 100), full feed-provided content. Body HTML trimmed to ~64 KB per article to keep transfers sane. Rough budget: ≤ ~10 MB total — fine for WC `transferFile` and for direct fetches.

Both paths produce the same snapshot shape:

- **Relay:** phone builds the snapshot from `ArticlesDatabase` (any account) and sends one file via `WCSession.transferFile` (background-queued, survives unreachability). Small deltas (a few status flips) use `transferUserInfo`.
- **Direct:** watch calls `GET /v1/entries?status=unread&order=published_at&direction=desc&limit=200` and `GET /v1/entries?starred=true`, using the `fields=` trimming already on this branch.

Cache replacement is snapshot-wins (minus pending-queue protection): articles no longer in the incoming set are evicted, except starred and currently-open ones.

## Credential handoff (direct path)

On the phone, when a Miniflux account exists and a watch is paired: send `{endpoint URL, credential}` via `WCSession.updateApplicationContext` (delivered when convenient, latest-wins). Watch stores the secret in its own keychain via `CredentialsManager` (which already works from any target in the keychain group; on watchOS it is simply the watch keychain). Re-sent whenever credentials change; a revoked account on the phone sends a tombstone that deletes the watch copy.

The watch does **not** run version detection on its own; the phone forwards the already-detected `MinifluxVersion` in the same context payload, and the watch degrades gracefully (skips batch endpoints) if it's stale.

## Reading experience

### Timeline

Root view: two sections — **Unread** and **Saved** (starred). Rows: feed name (caption, secondary color), title (2–3 lines), relative date. Unread dot on the leading edge. Swipe actions: toggle read, toggle star.

### Article view

Native SwiftUI rendering of feed-provided content — per the product decision, **no extraction pass**; if a feed ships summaries only, that's what you get, with the full article a "read on iPhone later" star away.

Renderer: extend the approach in `Shared/Extensions/NSAttributedString+Extensions.swift` (`NSAttributedString(simpleHTML:)`) into a watch-suitable `ArticleBodyParser` that walks the HTML once (RSParser's scanner primitives or an extension of the existing hand parser) and emits a `[BodyBlock]` model: paragraphs, headings, blockquotes, lists, code blocks, plain-text fallback for tables, and link ranges preserved as `AttributedString` links. SwiftUI `Text(AttributedString)` per block inside a `ScrollView`; crown scrolls.

Header: article title, feed name, byline, date. Footer actions: **Star/Unstar** (primary, save-for-later), **Mark unread**, **Open on iPhone** (handoff via `WCSession` when reachable). Marking read happens automatically on scroll-to-bottom or explicit action (setting, default: explicit).

Inline images: v1 skips them (placeholder glyph with alt text). Lead image thumbnails in rows are a possible follow-up; they change the transfer-size math.

## Theme support on the watch

The `.nnwtheme` format is HTML template + full CSS — not portable to native rendering. The watch gets a deliberately small native style model:

```swift
struct WatchTheme: Codable {
    var name: String
    var backgroundColor, textColor, secondaryTextColor, accentColor, linkColor: ThemeColor  // light/dark pair
    var bodyFont: BodyFont  // .system, .serif (New York), .rounded
}
```

Two levels of support:

1. **Built-in watch themes** (v1): Default, Sepia, High Contrast — hand-tuned equivalents of the shipped themes.
2. **Derived themes** (exploratory, v1.5): the phone parses the CSS *custom properties* out of an installed `.nnwtheme` stylesheet (`--article-title-color`, `--primary-accent-color`, etc. are plain color values, per `ArticleTheme.swift`'s structure) and ships a best-effort `WatchTheme` in the WC application context. Anything the CSS expresses beyond flat colors/font-family is dropped. If parsing fails, fall back to Default rather than rendering something broken.

Text size follows watchOS Dynamic Type; themes don't carry sizes.

## Sync triggers

- Foreground: sync on app open if last sync > 10 min old; manual sync button in settings; pull-to-refresh on the timeline.
- Background: `WKApplicationRefreshBackgroundTask` scheduled ~hourly; WC deliveries (file/context/userInfo) wake the app per the framework's normal behavior.
- Queue flush: attempted at the start of every sync, and opportunistically when reachability/network state changes.

## Milestones

1. **M1 — Scaffolding + relay.** Watch target, `Shared/Watch` snapshot/message schema, phone-side `WatchBridge`, watch store + queue, timeline + plain-text article view. Works with *any* account via relay. No direct sync yet.
2. **M2 — Direct Miniflux sync.** Extract `MinifluxAPI` package (pure move, iOS/macOS still building), watchOS platform additions, credential handoff, direct pull/flush in `SyncCoordinator`.
3. **M3 — Reading polish.** Block-based HTML renderer, built-in themes, auto-mark-read, Open on iPhone.
4. **M4 — Later.** Derived themes from `.nnwtheme`, Smart Stack widget/complication (unread count), lead-image thumbnails, per-feed cache selection.

## Risks / open items

- **No Mac/Xcode in this dev environment.** All of this requires building on a Mac; the plan is structured so M2's package extraction can be verified by existing-target builds first.
- **WC transfer limits.** `transferFile` handles multi-MB payloads but delivery latency is at the system's discretion; the snapshot format must tolerate arriving stale (it does — snapshot-wins + queue protection).
- **Miniflux server version drift** while traveling: watch trusts the phone-forwarded version; degrade path is the pre-2.3.2 per-entry endpoints already implemented in `MinifluxAPICaller`.
- **Battery**: direct-path polling is foreground/manual + hourly background at most; no continuous connectivity.
