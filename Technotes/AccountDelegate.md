# AccountDelegate and Activity Logging

How user and background actions flow through `AccountDelegate`, how `Account.logActivity`
and the progress machinery surface work back in the UI, and — for the Miniflux port — which
parts of a delegate are load-bearing versus copy-pasted boilerplate.

All file:line references are against the `miniflux-api` branch as of July 2026. Treat them as
signposts, not guarantees — verify before relying on an exact line.

---

## 1. The big picture

```
        user / timer / URL scheme
                  │
                  ▼
   ┌──────────────────────────────┐
   │  Account  (public API)       │   Modules/Account/…/Account.swift
   │  markArticles, addFeed, …    │
   │  logActivity(...)            │
   └──────────────┬───────────────┘
                  │  forwards 1:1
                  ▼
   ┌──────────────────────────────┐
   │  AccountDelegate (protocol)  │   AccountDelegate.swift
   │  concrete: MinifluxAccount…  │
   │   • mutates NNW model tree   │
   │   • reads/writes SyncDatabase│
   │   • wraps work in logActivity│
   │   • bumps RSProgress         │
   └──────────────┬───────────────┘
                  │  one Swift method per REST endpoint
                  ▼
   ┌──────────────────────────────┐
   │  MinifluxAPICaller           │   MinifluxAPICaller.swift
   │  pure HTTP + JSON, no domain │
   └──────────────────────────────┘

   Feedback back to the UI travels two independent channels:
     A. ActivityLog  → .activityDidChange       (what happened + errors)
     B. ProgressInfo → .progressInfoDidChange    (how far along a refresh is)
```

Two things to internalize up front:

- **`AccountDelegate` is `@MainActor` and almost entirely `async`/`throws`.** There are no
  completion-handler signatures in the protocol. Completion handlers exist only on the
  `Account` public surface, as a bridge for older/non-async callers.
- **The delegate owns all NNW-domain logic; the caller owns none.** `MinifluxAPICaller` never
  references `Account`, `Feed`, or `Folder`. This split is the single most important thing to
  preserve while simplifying.

---

## 2. `AccountDelegate` — the full contract

Defined at `Modules/Account/Sources/Account/AccountDelegate.swift:15-70` as
`@MainActor protocol AccountDelegate: ProgressInfoReporter`.

**Nothing in this protocol has a default implementation.** Every conformer
(`LocalAccountDelegate`, `FeedbinAccountDelegate`, `ReaderAPIAccountDelegate`,
`CloudKitAccountDelegate`, `FeedlyAccountDelegate`, `NewsBlurAccountDelegate`,
`MinifluxAccountDelegate`) must supply all of it. The only inherited member with a default is
`ProgressInfoReporter.postProgressInfoDidChangeNotification()`
(`Modules/RSCore/Sources/RSCore/RSProgress.swift:51-55`).

| Member | Line | Category |
|---|---|---|
| `var account: Account? { get set }` | 20 | infra (set weakly in `Account.init`) |
| `var behaviors: AccountBehaviors { get }` | 22 | infra |
| `var isOPMLImportInProgress: Bool { get }` | 24 | infra |
| `var server: String? { get }` | 26 | infra |
| `var credentials: Credentials? { get set }` | 27 | infra |
| `var accountSettings: AccountSettings? { get set }` | 28 | infra |
| `receiveRemoteNotification(userInfo:) async` | 30 | push (sync-only) |
| `refreshAll() async throws` | 32 | **core** |
| `syncArticleStatus() async throws -> Bool` | 35 | sync-only |
| `sendArticleStatus() async throws` | 36 | sync-only |
| `refreshArticleStatus() async throws` | 37 | sync-only |
| `importOPML(opmlFile:) async throws` | 39 | **core** |
| `createFolder(name:) async throws -> Folder` | 41 | **core** |
| `renameFolder(with:to:) async throws` | 42 | **core** |
| `removeFolder(with:) async throws` | 43 | **core** |
| `createFeed(url:name:container:validateFeed:) async throws -> Feed` | 45 | **core** |
| `renameFeed(with:to:) async throws` | 46 | **core** |
| `addFeed(feed:container:) async throws` | 47 | **core** |
| `removeFeed(feed:container:) async throws` | 48 | **core** |
| `moveFeed(feed:sourceContainer:destinationContainer:) async throws` | 49 | **core** |
| `restoreFeed(feed:container:) async throws` | 51 | **core** (undo/OPML) |
| `restoreFolder(folder:) async throws` | 52 | **core** (undo/OPML) |
| `markArticles(articleIDs:statusKey:flag:) async throws` | 54 | **core** |
| `accountDidInitialize()` | 57 | infra hook |
| `accountWillBeDeleted()` | 59 | infra hook |
| `static validateCredentials(credentials:endpoint:) async throws -> Credentials?` | 61 | sync-only |
| `vacuumDatabases() async` | 63 | infra hook |
| `suspendNetwork()` | 66 | infra (iOS background) |
| `resume()` | 69 | infra (iOS background) |

"sync-only" = meaningful only when there is a remote server to reconcile with. See §5 for how
`LocalAccountDelegate` proves which of these can be no-ops.

---

## 3. How an action reaches the delegate

`Account` holds `var delegate: AccountDelegate` (`Account.swift:248`), assigned a concrete type
in `init` based on account type (`Account.swift:301-319`, e.g. `MinifluxAccountDelegate(dataFolder:)`).
Each public `Account` method is a thin forwarder. The mapping:

| Account public API | Line | Delegate call |
|---|---|---|
| `refreshAll()` (+ `triggerRefreshAll()` 469-473) | 475-477 | `delegate.refreshAll()` |
| `sendArticleStatus()` | 506-508 | `delegate.sendArticleStatus()` |
| `syncArticleStatus()` | 510-513 | `delegate.syncArticleStatus()` |
| `importOPML(_:completion:)` | 517-534 | `delegate.importOPML(opmlFile:)`, then `delegate.refreshAll()` to backfill history |
| `markArticles(articleIDs:statusKey:flag:)` | 591-593 | `delegate.markArticles(...)` |
| `createFeed(url:name:container:validateFeed:completion:)` | 682-691 | `delegate.createFeed(...)` |
| `addFeed(_:to:completion:)` | 671-680 | `delegate.addFeed(feed:container:)` |
| `removeFeed(_:from:completion:)` | 708-717 | `delegate.removeFeed(feed:container:)` |
| `moveFeed(_:from:to:completion:)` | 719-728 | `delegate.moveFeed(...)` |
| `renameFeed(_:name:)` | 730-732 | `delegate.renameFeed(with:to:)` |
| `restoreFeed(_:container:completion:)` | 734-743 | `delegate.restoreFeed(feed:container:)` |
| `addFolder(_:)` | 745-748 | `delegate.createFolder(name:)` |
| `removeFolder(_:completion:)` | 750-759 | `delegate.removeFolder(with:)` |
| `renameFolder(_:to:)` | 761-763 | `delegate.renameFolder(with:to:)` |
| `restoreFolder(_:completion:)` | 765-774 | `delegate.restoreFolder(folder:)` |
| `suspendNetwork()` / `resumeDelegate()` | 538-545 | `delegate.suspendNetwork()` / `resume()` |
| `prepareForDeletion()` | 560-562 | `delegate.accountWillBeDeleted()` |

`credentials`, `accountSettings`, and `server` are exposed on `Account` as computed properties
that read/write straight through to the delegate (`Account.swift:343, 364, 375, 383-397`). This
is why the Miniflux delegate's `credentials`/`accountSettings` `didSet` push into `caller`
(`MinifluxAccountDelegate.swift:39-49`) — that is the seam that keeps the HTTP layer authenticated.

### async vs. completion-handler

Two shapes appear on `Account`:

- **Direct `async throws`** — `refreshAll`, `markArticles`, `renameFeed`, `renameFolder`,
  `addFolder`, `sendArticleStatus`, `syncArticleStatus`.
- **Completion-handler bridges** — `addFeed`, `createFeed`, `removeFeed`, `moveFeed`,
  `restoreFeed`, `removeFolder`, `restoreFolder`, `importOPML`. Each wraps the async delegate
  call in `Task { @MainActor in … completion(.success/.failure) }`. Example:
  `Account.swift:671-680`. The delegate side is always pure async; the `Task`/`Result` bridge is
  only for legacy UI call sites.

Background actions (timer-driven refresh, background-app-refresh, remote push) enter through the
exact same doors — `refreshAll()`, `syncArticleStatus()`, `receiveRemoteNotification(userInfo:)`.
There is no separate "background" path into the delegate.

---

## 4. Feedback back to the UI — two channels

### Channel A: `ActivityLog` (what happened, and errors)

`Account.logActivity` has two overloads — async (`Account.swift:482-490`) and sync
(`494-502`) — both `@discardableResult`. They forward to
`ActivityLog.shared.logActivity(owner:kind:detail:successMessage:durationIsSignificant:work:)`,
passing `activityOwner` (`Account.swift:130`, an `.account(accountID:displayName:)`).

`ActivityLog` (`Modules/ActivityLog/Sources/ActivityLog/ActivityLog.swift`) is a `@MainActor`
singleton. Its `logActivity` (async overload lines 76-94):

1. creates an `Activity` and moves it to running via `didStart(id:)`,
2. runs `work()`,
3. on success calls `didComplete(id:…)`; on throw calls `didFail(id:error:)` and **rethrows**.

Every transition posts `Notification.Name.activityDidChange` (declared ~line 10-13). So
`logActivity` is a *wrapper*, not a fire-and-forget log: it times the work, records success/failure,
and re-raises errors unchanged. This is why delegates wrap essentially every unit of work in it —
e.g. `MinifluxAccountDelegate.swift:77` (`.refreshAll`), `:111` (`.sendArticleStatuses`),
`LocalAccountDelegate.swift:74` (`.importOPML`), `:98` (`.subscribeFeed`).

UI observers of `.activityDidChange`:
- `Shared/CurrentActivity/CurrentActivityViewModel.swift:34,42`
- `iOS/Settings/ActivityLogView.swift:56`
- `iOS/MainFeed/MainFeedCollectionViewController.swift:91,103`
- `Mac/ActivityLog/ActivityLogWindowController.swift:51`

### Channel B: `ProgressInfo` (how far along)

This is the spinner/progress-bar channel, entirely separate from `ActivityLog`.

- `ProgressInfoReporter` (`RSProgress.swift:43-55`) posts `.progressInfoDidChange` whenever its
  `progressInfo` changes.
- A remote delegate owns an `RSProgress` task counter (`refreshProgress`) and bumps it as work
  proceeds (`MinifluxAccountDelegate.swift:37, 73-74`). It observes that counter's
  `.progressInfoDidChange` (`:61`) and republishes its own `progressInfo` in
  `progressInfoDidChange(_:)`.
- `Account` observes its delegate's `.progressInfoDidChange` (`Account.swift:337`) and re-posts
  its own (`Account.swift:1127-1129`; `Account` is itself a `ProgressInfoReporter`,
  `Account.swift:95`).
- `CombinedRefreshProgress` (singleton) aggregates `progressInfo` across all active accounts
  (`Modules/Account/…/CombinedRefreshProgress.swift`) and posts one combined
  `.progressInfoDidChange`.

UI observers of the combined progress:
- `iOS/SceneCoordinator.swift:352`, `iOS/MainFeed/RefreshProgressView.swift:39,77`
- `Mac/MainWindow/MainWindowController.swift:109`, `Mac/MainWindow/Sidebar/SidebarStatusBarView.swift:36,48`

### Errors

Thrown errors propagate up the `async throws` chain and reach the UI either via the
`Result.failure` in a completion bridge or as a thrown error on an `async` call. `AccountError`
(`Modules/Account/…/AccountError.swift`) is a `LocalizedError` with cases like
`createErrorAlreadySubscribed`, `opmlImportInProgress`, `invalidResponse`, and
`wrappedError(error:accountID:accountName:)`. Delegates wrap service errors with
`AccountError.wrapped(error, account)` (e.g. `MinifluxAccountDelegate.swift:83`) so the account
name is attached before display. Separately, delegates post `.appDidEncounterError` via a
`postSyncError(...)` helper (`MinifluxAccountDelegate.swift:134`) which feeds the persistent
`ErrorLog` — distinct from `ActivityLog`.

---

## 5. What's actually required — `LocalAccountDelegate` as the baseline

`LocalAccountDelegate` (`Modules/Account/…/LocalAccount/LocalAccountDelegate.swift`) is the
minimal functioning delegate: a local RSS account with no server. What it implements with real
logic vs. what it leaves as a no-op is the clearest map of "core account" vs. "sync-only":

**Real work (≈13 methods):** `refreshAll` (46-58), `importOPML` (70-88),
`createFeed` (90-101 → private 188-230), `renameFeed`/`removeFeed`/`moveFeed`/`addFeed`/
`restoreFeed` (103-122, plain tree mutations, no network), `createFolder`/`renameFolder`/
`removeFolder`/`restoreFolder` (124-144), `markArticles` (146-148), `suspendNetwork`/`resume`
(165-171).

**No-ops (pure protocol satisfaction):** `receiveRemoteNotification` (43-44),
`syncArticleStatus` → `false` (60-62), `sendArticleStatus` (64-65), `refreshArticleStatus`
(67-68), `accountDidInitialize` (150-151), `accountWillBeDeleted` (153-154),
`validateCredentials` → `nil` (156-158), `vacuumDatabases` (160-161).

The no-op set is exactly the "sync-only / infra hook" rows from §2. For Miniflux, these are the
methods that *must* exist but should stay as small as their job actually requires — don't pad
them with copied ceremony.

---

## 6. Current Miniflux structure

Files under `Modules/Account/Sources/Account/Miniflux/`:

- `MinifluxAccountDelegate.swift` — ~957 lines. All domain logic.
- `MinifluxAPICaller.swift` — ~326 lines. Pure transport + decoding.
- DTOs / small helpers: `MinifluxCategory.swift`, `MinifluxEntry.swift`, `MinifluxFeed.swift`,
  `MinifluxUser.swift`, `MinifluxVersion.swift`, `MinifluxError.swift`, `Miniflux.swift` (logger only).

**Delegate → caller mapping (current):**
- `refreshAll` (67-85) → `refreshAccount` (categories + feeds in parallel via `async let`) +
  `refreshArticlesAndStatuses`
- `sendArticleStatusReturningCount` (104-137) → `caller.updateEntries(entryIDs:status:)` /
  `updateEntries(entryIDs:starred:)`
- `refreshArticleStatusReturningCount` (148-181) → `caller.retrieveUnreadEntryIDs()` /
  `retrieveStarredEntryIDs()`
- `createFolder`/`renameFolder`/`removeFolder` (211-285) → category CRUD (+ per-feed delete on
  folder removal)
- `createFeed` (288-318) → `caller.createFeed(url:categoryID:)` then `retrieveFeed(feedID:)`
- `renameFeed`/`removeFeed`/`moveFeed`/`addFeed` (320-419) → feed CRUD
- `refreshArticlesPage` (730-749) → `caller.retrieveEntries(offset:changedAfter:publishedAfter:)`
- `validateCredentials` (491-499) → `caller.validateCredentials(endpoint:)`

The split is already clean: the delegate does `guard account/id → refreshProgress.addTask →
logActivity { call caller, mutate model } → wrap errors`, and the caller has zero NNW-domain
references. This is tighter than ReaderAPI or Feedbin already.

---

## 7. Simplification targets for the Miniflux port

Miniflux has already shed two big pieces of ReaderAPI baggage — keep them gone:

1. **No `folderRelationship` dictionary.** ReaderAPI maintains a per-feed `folderRelationship`
   map (`ReaderAPIAccountDelegate.swift:790-853`, `918-935`) plus a multi-folder guard in
   removal (`:322-327`) because its API allows one feed under many tags. Miniflux feeds have one
   `category.id`, so folder membership is re-derived on every refresh
   (`MinifluxAccountDelegate.swift:651-653`, `.disallowFeedInMultipleFolders` at `:23`). Note the
   Miniflux method named `syncFeedFolderRelationship` (~653-692) is *not* the ReaderAPI dict — it's
   a stateless re-derivation. Don't let a future copy-paste reintroduce the dictionary.

2. **No credentials retry-on-401 dance.** ReaderAPI's `refreshAll` has a whole basic-auth
   fallback + recurse path (`:133-158`). Miniflux tries both credential types once in
   `retrieveCredentialsIfNeeded` and stops. That's correct for Miniflux; resist porting the loop.

Candidates still worth reducing (all are boilerplate duplicated across every remote delegate,
not Miniflux-specific bugs):

- **The progress double-bookkeeping.** Every remote delegate carries *both* a `ProgressInfo`
  (for `ProgressInfoReporter`) and a separate `RSProgress` `refreshProgress`, bridged by an
  identical `@objc progressInfoDidChange(_:)` + `NotificationCenter.addObserver` in `init`
  (`MinifluxAccountDelegate.swift:30-37, 61`; verbatim in Feedbin/ReaderAPI). The `ProgressInfo`
  side is required by the protocol; the observer-wiring boilerplate is a candidate to extract into
  a shared helper or protocol extension rather than re-typing per delegate. `LocalAccountDelegate`
  reaches the same end by forwarding its refresher's `progressInfo` directly (`:24-30, 175-177`) —
  evidence the NotificationCenter round-trip isn't the only way.
- **`postSyncError`** is duplicated near-verbatim across Miniflux (`:953-956`), ReaderAPI, and
  Feedbin, and touches only `account` + `self` — a clean extract to a protocol extension or free
  function.
- **`isOPMLImportInProgress` as a manually toggled `var`** (`:24`, flipped around one call site,
  `:193-198`) could be scoped tighter, though it's minor.

Rule of thumb while trimming: anything that only exists to satisfy the protocol should be as
small as `LocalAccountDelegate`'s version of it; anything that mutates the NNW model or reads/writes
`SyncDatabase` stays in the delegate; anything that speaks HTTP/JSON stays in `MinifluxAPICaller`;
and no NNW-domain type should ever cross into the caller.

---

## 8. Quick reference — where to look

| I want to… | Look at |
|---|---|
| See the full delegate contract | `AccountDelegate.swift:15-70` |
| See the minimal delegate | `LocalAccount/LocalAccountDelegate.swift` |
| See how a UI action forwards to the delegate | `Account.swift:591-774` |
| Understand `logActivity` | `Account.swift:482-502` + `ActivityLog/…/ActivityLog.swift` |
| Understand refresh progress | `RSProgress.swift:43-55`, `CombinedRefreshProgress.swift` |
| See error wrapping | `AccountError.swift`, `MinifluxAccountDelegate.swift:83,134` |
| Current Miniflux domain logic | `Miniflux/MinifluxAccountDelegate.swift` |
| Current Miniflux HTTP layer | `Miniflux/MinifluxAPICaller.swift` |
