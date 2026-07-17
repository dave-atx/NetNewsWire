# NetNewsWire for Apple Watch — Design

Status: design approved by Dave 2026-07-16; reviewed and corrected 2026-07-16 (on-Mac codebase spot-check + SwiftUI/watchOS review). Nothing implemented yet — next step is M1.

## Handoff context (for the implementing agent)

- Branch `watch-app` is based on `miniflux-api` (not yet merged to `main`), which adds the native Miniflux account type this design reuses. Don't rebase onto `main`; Miniflux support only exists here.
- Product decisions already made by Dave — don't re-ask:
  - Sync: phone relay when reachable + direct Miniflux sync when not (his primary use case is traveling with WiFi-only, away from the phone).
  - Cache: recent unread (~200) + all starred.
  - Save-for-later = starring. No new concept.
  - Article view renders feed-provided content only — no Mercury/extraction pass in v1. (watchOS has no Safari reader API; that option was already ruled out.)
  - Theme support: built-in native watch themes first; deriving colors from installed `.nnwtheme` files is a later exploration (v1.5), not v1.
  - Minimum target: **watchOS 26**; optimize for the Apple Watch Ultra form factor first (Dave, 2026-07-16).
- Work milestone by milestone (M1 first) as ordered below. For rote implementation work, Dave wants Sonnet low-effort subagents; exploration on Haiku/Sonnet low effort.
- This design was written on a Linux box with no Xcode — nothing has been built. Before adding watch code, verify the repo still builds on macOS as-is (`./buildscripts/build_and_test.sh` or the xcodebuild commands in CLAUDE.md).
- Facts verified by codebase exploration (re-checked on-Mac 2026-07-16): no watchOS target exists in the project; no module's `Package.swift` declares watchOS in `platforms:`; `CredentialsManager` (Modules/Secrets) derives its keychain access group from the `AppGroup` Info.plist key and imports only watchOS-safe frameworks (Foundation, os, Security, RSCore, ErrorLog); `NSAttributedString(simpleHTML:)` in `Shared/Extensions/NSAttributedString+Extensions.swift` is the existing non-WebKit HTML converter to extend. Corrections from the original Linux-side pass: `MinifluxEntry.swift` also imports **RSParser** (`DateParser`), so the extracted package needs RSParser too; the Miniflux directory also contains `Miniflux.swift` (shared `Logger` namespace); `Credentials` is `Equatable`/`Sendable` but **not `Codable`**; `Secrets` depends on `ErrorLog` and `RSCore`, so both need watchOS platforms as well. RSCore/RSWeb gate their UIKit/AppKit files with `#if os(iOS)` / `#if os(macOS)` (not `canImport`), so they compile out cleanly on watchOS.

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

- `MinifluxAPICaller.swift`, `MinifluxEntry.swift`, `MinifluxFeed.swift`, `MinifluxCategory.swift`, `MinifluxUser.swift`, `MinifluxVersion.swift`, `MinifluxError.swift`, `Miniflux.swift` (the shared `Logger` namespace)

Package dependencies: Foundation + RSWeb + RSParser (`MinifluxEntry` uses `DateParser`) + Secrets — no UIKit/AppKit. The `Account` package then depends on `MinifluxAPI`; `MinifluxAccountDelegate` stays in `Account` and keeps orchestrating. This is a move plus `public` access-level additions (the types are `internal` to `Account` today), verified by building the existing targets before any watch code lands.

### Platform additions

Add `.watchOS(.v26)` to `platforms:` in `Package.swift` for: `Secrets`, `ErrorLog` and `RSCore` (Secrets depends on both), `RSWeb`, `RSParser` (HTML entity decoding + `DateParser`), and the new `MinifluxAPI`. Minimum target is watchOS 26 (decided 2026-07-16): the Ultra is the primary device, so nothing holds APIs to older SDKs. Audit for watch-unavailable API at compile time; the keychain APIs `CredentialsManager` uses are watchOS-safe, and RSCore/RSWeb's platform-specific files are `#if os(iOS)`/`#if os(macOS)`-gated so they compile out.

Deliberately **not** ported to watchOS: `Account`, `ArticlesDatabase`, `SyncDatabase`, `RSDatabase`. The watch store is small enough that pulling in FMDB/SQLite machinery is unjustified weight.

### New targets

- `NetNewsWire Watch App` — single-target watchOS app (SwiftUI), embedded in `NetNewsWire-iOS`. Own Info.plist + entitlements, joins the existing App Group (`$(APP_GROUP_ID)`) following the Widget/Intents/Share extension precedent. Note: the watch has its *own* keychain — app-group keychain sharing does not span devices; credentials arrive via WatchConnectivity (below).
- Shared watch-adjacent code that the iOS app needs (snapshot model, WC message schema) lives in `Shared/Watch/`, compiled into both the iOS and watch targets. Every WC payload and the snapshot carry an explicit `schemaVersion` — the phone and watch apps can run mismatched versions for days, so both sides must reject-or-degrade on unknown versions rather than misparse.

## Watch-side storage

No SQLite. Codable stores in the watch app's container, written atomically:

- **`WatchStore`** — the article cache, split in two so status flips stay cheap and timeline rows stay light:
  - a **metadata index** (one small JSON file): `WatchArticleSummary` per article — `articleID`, `minifluxEntryID?`, `feedName`, `title`, `textPreview` (first ~200 chars plain text, for rows), `datePublished`, `url`, `read`, `starred`. `Identifiable` by `articleID`, `Equatable`. Rewritten atomically on every mutation — it's small, so that's fine.
  - **per-article content files**: the pre-trimmed feed-provided `contentHTML`, one file per article, written once on arrival, deleted on eviction, loaded on demand by the article view. (A single monolithic JSON blob would mean rewriting up to ~19 MB on every read/star toggle, and would drag 64 KB bodies through SwiftUI's value comparisons on every timeline diff.)
- **`StatusQueue`** — mirror of the `SyncStatus` shape: `(articleID, minifluxEntryID?, key: read|starred, flag, attemptState)`. Same selected-for-processing semantics as `SyncDatabase`: mark in-flight, delete on confirmed send, reset on failure. Persisted so a terminated app loses nothing.

`minifluxEntryID` is carried alongside NNW's `articleID` so the direct path can address Miniflux entries without a lookup table.

## Cache policy

"Recent unread + starred": newest **200 unread** articles (across all feeds, by `datePublished`) plus **all starred** (capped at 100), full feed-provided content. Body HTML trimmed to ~64 KB per article to keep transfers sane. Worst case is ~19 MB (300 × 64 KB); typical feed content lands far below that. Treat ~10 MB as the working budget and trim harder (or lower the caps) if real snapshots trend above it — still fine for WC `transferFile` and for direct fetches.

Both paths produce the same snapshot shape:

- **Relay:** phone builds the snapshot from `ArticlesDatabase` (any account) and sends one file via `WCSession.transferFile` (background-queued, survives unreachability). Small deltas (a few status flips) use `transferUserInfo`.
- **Direct:** watch calls `GET /v1/entries?status=unread&order=published_at&direction=desc&limit=200` and `GET /v1/entries?starred=true`. Note on `fields=` trimming: it exists only on Dave's patched server (unmerged upstream; would require ≥ 2.3.2) — stock servers return full entries, so the direct path must tolerate untrimmed payloads, and `fields=` should be gated on the phone-forwarded server version rather than sent unconditionally (today `MinifluxAPICaller` sends it unconditionally).

Cache replacement is snapshot-wins (minus pending-queue protection): articles no longer in the incoming set are evicted, except starred and currently-open ones.

## Credential handoff (direct path)

On the phone, when a Miniflux account exists and a watch is paired: send the **non-secret** config `{endpoint URL, MinifluxVersion, schemaVersion}` via `WCSession.updateApplicationContext` (delivered when convenient, latest-wins). The **secret** travels separately — `sendMessage` when the watch is reachable, else `transferUserInfo` (queued, delivered once) — because `updateApplicationContext` persists its payload in a plist on both devices indefinitely and re-delivers it; a credential shouldn't live there. On receipt the watch stores the secret in its own keychain via `CredentialsManager` (which already works from any target; on watchOS it is simply the watch keychain) and persists it nowhere else. Re-sent whenever credentials change; a revoked account on the phone sends a tombstone that deletes the watch copy. `Credentials` is not `Codable` — the WC schema defines its own plist-safe dictionary encoding (credential type, username, secret) rather than encoding the type directly.

The watch does **not** run version detection on its own; the phone forwards the already-detected `MinifluxVersion` in the application context, and the watch degrades gracefully (skips batch endpoints) if it's stale.

## Reading experience

### Timeline

Root view: two sections — **Unread** and **Saved** (starred). Rows: feed name (caption, secondary color), title (2–3 lines), relative date. Unread dot on the leading edge. Swipe actions: toggle read, toggle star.

SwiftUI notes: navigation is a `NavigationStack` (`NavigationView` is soft-deprecated). The store is a `@MainActor @Observable` class exposing **precomputed** `unread` and `starred` arrays, recomputed when the cache or queue mutates — never filter/sort inline in `body`. Rows iterate `ForEach(store.unread)` with `WatchArticleSummary: Identifiable` (id = `articleID`, stable and cheap to hash — never `id: \.self` or indices); the row view is unary (single root container) and takes the summary value (small and `Equatable`, so diffing is cheap) — the metadata/content split above is what keeps 64 KB bodies out of row inputs. Lay out in relative terms so the Ultra's 49 mm screen gets used while smaller watches stay correct.

### Article view

Native SwiftUI rendering of feed-provided content — per the product decision, **no extraction pass**; if a feed ships summaries only, that's what you get, with the full article a "read on iPhone later" star away.

Renderer: extend the approach in `Shared/Extensions/NSAttributedString+Extensions.swift` (`NSAttributedString(simpleHTML:)`) into a watch-suitable `ArticleBodyParser` that walks the HTML once (RSParser's scanner primitives or an extension of the existing hand parser) and emits a `[BodyBlock]` model: paragraphs, headings, blockquotes, lists, code blocks, plain-text fallback for tables, and link ranges preserved as `AttributedString` links. SwiftUI `Text(AttributedString)` per block inside a `ScrollView` + `LazyVStack` (long articles are hundreds of blocks; don't build them eagerly); crown scrolls. Content HTML is loaded on demand from the per-article file, parsed off the main actor once, and the resulting blocks cached. Link taps: watchOS has no browser — install a custom `OpenURLAction` that offers **Open on iPhone** (immediate when reachable, else queued) or **Star this article**; links render styled but never dead-end.

Header: article title, feed name, byline, date. Footer actions: **Star/Unstar** (primary, save-for-later), **Mark unread**, **Open on iPhone** (handoff via `WCSession` when reachable). Star also binds to the double-tap gesture via `.handGestureShortcut(.primaryAction)` (S9/Ultra 2 and later; silent no-op on older hardware). Marking read happens automatically on scroll-to-bottom or explicit action (setting, default: explicit); scroll-to-bottom detection is `onScrollVisibilityChange` on an end-of-article sentinel view. Under always-on dimming (`isLuminanceReduced`) timeline and article render statically — no animated elements.

Inline images: v1 skips them (placeholder glyph with alt text). Lead image thumbnails in rows are a possible follow-up; they change the transfer-size math.

## Theme support on the watch

The `.nnwtheme` format is HTML template + full CSS — not portable to native rendering. The watch gets a deliberately small native style model:

```swift
struct WatchTheme: Codable {
    var name: String
    var backgroundColor, textColor, secondaryTextColor, accentColor, linkColor: ThemeColor  // single color — watchOS renders dark-only
    var bodyFont: BodyFont  // .system, .serif (New York), .rounded
}
```

watchOS has no light/dark distinction (the environment is effectively always dark), so themes carry one palette, tuned for dark backgrounds and legible under always-on dimming.

Two levels of support:

1. **Built-in watch themes** (v1): Default, Sepia, High Contrast — hand-tuned equivalents of the shipped themes.
2. **Derived themes** (exploratory, v1.5): the phone parses the CSS *custom properties* out of an installed `.nnwtheme` stylesheet (`--article-title-color`, `--primary-accent-color`, etc. are plain color values, per `ArticleTheme.swift`'s structure) and ships a best-effort `WatchTheme` in the WC application context. Anything the CSS expresses beyond flat colors/font-family is dropped. If parsing fails, fall back to Default rather than rendering something broken.

Text size follows watchOS Dynamic Type; themes don't carry sizes.

## Sync triggers

- Foreground: sync on app open if last sync > 10 min old; manual sync button in settings; pull-to-refresh on the timeline.
- Background: app refresh scheduled ~hourly, handled via the SwiftUI `.backgroundTask(.appRefresh)` scene modifier. Any *network* work in a background refresh must go through a background `URLSession` handed back via `WKURLSessionRefreshBackgroundTask` — an in-process async request gets suspended when the short background runtime window ends. Foreground syncs use a normal session. WC deliveries (file/context/userInfo) wake the app per the framework's normal behavior.
- Queue flush: attempted at the start of every sync, and opportunistically when reachability/network state changes.

## Milestones

1. **M1 — Scaffolding + relay.** Watch target, `Shared/Watch` snapshot/message schema, phone-side `WatchBridge`, watch store + queue, timeline + plain-text article view. Works with *any* account via relay. No direct sync yet.
2. **M2 — Direct Miniflux sync.** Extract `MinifluxAPI` package (move + `public` access + RSParser dependency, iOS/macOS still building), watchOS platform additions, credential handoff, direct pull/flush in `SyncCoordinator`.
3. **M3 — Reading polish.** Block-based HTML renderer, built-in themes, auto-mark-read, Open on iPhone.
4. **M4 — Later.** Derived themes from `.nnwtheme`, Smart Stack widget/complication (unread count), lead-image thumbnails, per-feed cache selection.

## Risks / open items

- **No Mac/Xcode in this dev environment.** All of this requires building on a Mac; the plan is structured so M2's package extraction can be verified by existing-target builds first.
- **WC transfer limits.** `transferFile` handles multi-MB payloads but delivery latency is at the system's discretion; the snapshot format must tolerate arriving stale (it does — snapshot-wins + queue protection).
- **Miniflux server version drift** while traveling: watch trusts the phone-forwarded version; degrade path is the pre-2.3.2 per-entry endpoints already implemented in `MinifluxAPICaller`.
- **Battery**: direct-path polling is foreground/manual + hourly background at most; no continuous connectivity.
