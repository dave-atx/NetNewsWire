# App Intents and Siri: Status and Handoff

Where the App Intents / Siri work stands, what was learned testing it on real devices, and what's
next. Written 2026-10-14 for whoever picks this up next, human or agent.

This note lives on `daily-driver` only. Hashes are as of 2026-10-14 and change on every rebase:
find the commits by their `Topic: app-intents` trailer (see §1), not by hash.

---

## 1. Branches, commits, and tracking

App Intents commits carry a **`Topic: app-intents`** trailer, so they can be found after any rebase:

```
git log --oneline --grep='Topic: app-intents' daily-driver
```

| `daily-driver` | `app-intents` | Commit |
|---|---|---|
| `0a4b297f5` | `c26770912` | Make the Add Feed App Intent available on the Mac |
| `32b1ac099` | `c8b04a55c` | Add App Intents entities for feeds and articles |
| `fe8d8ddf2` | `8b1a03fd1` | Tell Siri which article or feed is on screen |
| `1418ea17c` | `396c49d60` | Replace the Add Feed App Intent with one that adds the feed itself |
| `011d4c6e0` | `ca9e49ef1` | Show each account's type and icon in the App Intents account picker |
| `920b51159` | `7b91b41ed` | Show a folder's account in the App Intents picker only when it's ambiguous |

- **`app-intents`** is a local branch off `upstream/main` (`7209509da`) holding clean cherry-picks of
  just those six. **Not pushed.** The first three were build-checked there (Mac); the rest
  cherry-picked cleanly and their files match `daily-driver`, which builds on both platforms, but
  weren't built separately on this branch. To regenerate: branch from a
  fresh `upstream/main` and cherry-pick the grep's commits, oldest first. Use a scratch worktree; see
  [Rebase hazards](#7-environment-gotchas).
- **Before an upstream PR:** strip the `Topic:` trailers and probably squash. Keep diffs minimal and
  in the house style.
- **Related commits on `daily-driver` that aren't App Intents** (no trailer):
  - `90b488e3d` *Use APP_GROUP_ID for the Mac extensions' AppGroup*. A real upstream bug fix, worth
    its own small PR (§5).
  - `cfea8c391` *Let personal Mac builds use a team-ID-prefixed app group*. **Personal, never upstream.**
  - `dd3489fd8` *Unregister the tests' Debug host app after a Release install's tests*. Personal
    (`dave-install.sh`).
- **TestFlight (iOS, via Xcode Cloud):** `dave-testflight-11` = commits 1–3; `dave-testflight-12` =
  all six. `origin/daily-driver` is at `920b51159`.
- **Backup refs** from the 2026-10-14 history cleanup: `refs/backup/daily-driver-pre-picker-squash`,
  `refs/backup/app-intents-pre-picker-squash`. Safe to delete once this is settled.

---

## 2. What's built

All App Intents code is in `Shared/AppIntents/`, built by both the Mac and iOS apps.

### Add Feed

- **`SubscribeToFeedIntent`** (shown as **"Add Feed"**) is the current action. It isn't called
  `AddFeedIntent` because `ActivityType.addFeedIntent` already uses that string.
  - **URL** parameter, plus **Account** (`AccountEntity`) and **Folder** (`FolderEntity`) pickers.
    The folder list follows the chosen account via `@IntentParameterDependency`.
  - **Defaults** to the Add Feed sheet's remembered container (`AddFeedDefaultContainer`). If only an
    account is chosen, it uses the remembered folder when that folder is in the account, rather than
    the alphabetically first folder.
  - **Creates the feed in-process** (`account.createFeed`) and returns the `FeedEntity` with an
    "Added X to Folder in Account." dialog. Failures throw `SubscribeToFeedIntentError` with a
    specific message: already added, no feed found, folder not in account, and so on. It runs the
    same already-subscribed check as the Mac sheet (`AddFeedController`).
  - **Mode:** `supportedModes = .background` on 26+. Before 26 the default is background anyway.
- **`AddFeedAppIntent`** is the old action, by Brent, August 2026. It shipped in **iOS 7.1.3**, so
  saved shortcuts depend on it.
  - It now has `isDiscoverable = false`: hidden from the action list, but saved shortcuts still run.
    **Don't rename it or change its parameters.**
  - It takes exact-match name strings and enqueues the request through the app-group file queue
    (`ExtensionFeedAddRequestFile`), like the share extension. It drops failures silently.
- **`NetNewsWireAppShortcuts`:** the phrases "Add a feed to NetNewsWire" / "Add feed in NetNewsWire"
  now run `SubscribeToFeedIntent`.

**Why in-process instead of the queue:** the queue dates from the legacy SiriKit intent, which ran in
a separate Intents *extension* (`iOS/IntentsExtension/`, removed in `b5b8d5de5`) with no database
access. App Intents in the app target run inside the app, so the hand-off is unnecessary. It was also
harmful: silent failures, and a dependency on a stale shared-folder account list.
- **The trade-off:** a background intent on iOS gets about 30 s. Finding and checking a feed is
  usually 1–5 s. If slow sites time out, use `[.background, .foreground(.dynamic)]` and continue in
  the foreground (26+).

### Entities

- **`AccountScopedEntityID`** is `"<accountID>/<itemID>"`, split on the first slash. Account IDs are
  UUIDs, `OnMyMac` or `iCloud`, so they never contain one. **This format is a public contract once
  shipped:** saved shortcuts and onscreen annotations store it.
- **`FeedEntity`:** name, account, URL, home page, unread count. `EntityStringQuery`: searches by name
  and suggests every feed.
- **`ArticleEntity`:** title, feed, byline, URL, date, read, starred.
  - **`Transferable`** as plain text (title, body, link) and HTML. This is what lets Apple
    Intelligence "summarize this".
  - Its query suggests the 50 newest unread articles and searches with `FetchType.search`.
  - It carries the full article text in the entity. Fine at the 50-result cap; it could become a
    `@DeferredProperty` on 26+.
- **`AccountEntity`:** name, type, icon. Subtitle = type, left off when the account has its default
  name. `EntityStringQuery` matches name or type.
- **`FolderEntity`:** ID = account ID plus folder display name, like `ContainerIdentifier`. Renaming a
  folder breaks saved references, same as everywhere else. Its subtitle (account name) shows only
  when the list mixes folders from several accounts.

### Onscreen "this"

- `ActivityManager` sets `appEntityIdentifier` on the **ReadArticle** activity (`ArticleEntity`) and
  the **SelectFeed** activity (`FeedEntity`), gated to macOS 15.2 / iOS 18.2.
- **Mac gap:** the Mac never creates a SelectFeed activity. `MainWindowController` only calls
  `activityManager.reading(...)`, so on the Mac only articles resolve as "this".

---

## 3. Device test results (macOS 27, 2026-10-14)

| Test | Result |
|---|---|
| "Summarize this" with an article open | ✅ Works |
| "Read this aloud" with an article open | ❌ "The device doesn't support it." Siri's limitation; nothing in App Intents controls it |
| Siri: "add this feed to NetNewsWire" in Safari | ❌ Siri answers from the web. Free-form requests reach only schema-adopting intents, and no schema covers subscribing to a feed |
| Siri: exact phrase "Add a feed to NetNewsWire" | ❌ Siri answers from netnewswire.com instead of running the App Shortcut. **Unexplained:** the metadata is correct and the action is indexed. Not yet checked: System Settings → Apple Intelligence & Siri app access; whether NetNewsWire appears under App Shortcuts in the Shortcuts sidebar |
| Shortcuts "describe a shortcut" (AI) with NetNewsWire | ❌ "To create a shortcut using NetNewsWire, you'll need to use the editor." Unexplained |
| Old `AddFeedAppIntent` in Shortcuts | ✅ After the app-group fix, but only when everything lines up (§4) |
| New `SubscribeToFeedIntent` in Shortcuts | ✅ Works; account and folder pickers behave as designed |
| iOS (TestFlight 12) | ⏳ Not yet tested |

**Picker presentation findings:**
- An `EntityStringQuery` gives a searchable popover list. A plain `EntityQuery` gave a menu with no
  search, but Shortcuts **clipped the name** ("marquard.or") and **dropped the subtitle** in it.
  Adding an icon didn't fix the clipping.
- Dave chose search with subtitle and icon. The menu attempt was reverted and dropped from history.
- A plain `EntityQuery` also loses text-to-entity resolution, so Text variables can't fill the
  parameter.

---

## 4. Why the old Add Feed failed ("There are no accounts to add the feed to")

Three separate causes stacked up, and the old intent reports any failure to read the account list
with that same message:

1. **The app-group folder was unreadable on Dave's Mac builds.**
   - Personal builds use `DEVELOPER_ENTITLEMENTS = -dev`, which strips iCloud and push, so automatic
     signing picks the wildcard "Mac Team Provisioning Profile: *" or embeds no profile at all.
   - macOS 15+ grants a `group.`-prefixed app group without prompting only when the profile
     authorizes it. Background contexts can't prompt, so reads fail silently.
   - The app logged `Couldn't read values … Domain: group.org.marquard.NetNewsWire-Evergreen …
     Container: (null)` at launch.
   - The Mac share extension and Safari "Subscribe to Feed" were affected the same way.
   - **Fix:** §5.
2. **The shared account list was stale.** `extension_containers.plist` is written only when accounts
   or folders change, so it still had the account's old name ("Miniflux" rather than
   "marquard.org").
3. **"First account" picked a broken account.** A credential-less FreshRSS account sorted before
   Miniflux. A blank Account meant the feed went there, failed (`missing endpoint URL`), and the
   queue processor dropped the error. Dave has since removed that account.

---

## 5. Signing and app-group setup (personal Mac builds)

- **`APP_GROUP_PREFIX`** is defined (default `group.`) in
  `xcconfig/common/NetNewsWire_codesigning_common.xcconfig`, *before* the DeveloperSettings include.
  It feeds the Mac `APP_GROUP_ID` in `NetNewsWire_mac_target_common.xcconfig`.
- **Dave's `../SharedXcodeSettings/DeveloperSettings.xcconfig`** sets `APP_GROUP_PREFIX = 5WM6947328.`.
  macOS always grants a team-ID-prefixed group to that team's apps, with no profile and no prompt.
  - Result: Release group `5WM6947328.org.marquard.NetNewsWire-Evergreen`, Debug
    `…-Evergreen-DEBUG`.
  - The data now lives in a fresh container,
    `~/Library/Group Containers/5WM6947328.org.marquard.NetNewsWire-Evergreen/`.
- **`90b488e3d`:** the Mac share and Safari extensions had hard-coded `group.$(ORGANIZATION_IDENTIFIER)…`
  in their Info.plists instead of `$(APP_GROUP_ID)`. They ignored `APP_GROUP_SUFFIX` and could
  disagree with the app. Fixed; worth upstreaming.
- **What did *not* help:**
  - registering `group.org.marquard.NetNewsWire-Evergreen` on the Mac App IDs in the developer portal
    (done 2026-10-14, harmless);
  - `xcodebuild -allowProvisioningUpdates`, which still picks the wildcard because no entitlement
    requires an explicit profile.
- **`dave-install.sh`'s Signature step now runs `verify_app_groups`.** It warns when an entitlement
  group is neither team-prefixed nor authorized by the embedded profile.
- **Debug builds** still define `SKIP_APP_GROUP_ACCESS`, which skips the containers file and the
  feed-add queue. Only the *old* intent and the extensions depend on those; the new intent doesn't.

---

## 6. Next steps

**Testing and decisions**
1. Test `SubscribeToFeedIntent` on iOS (TestFlight 12): a fresh Add Feed action, website vs feed URL,
   already-subscribed, and a slow site against the ~30 s limit.
2. Investigate why Siri won't run the App Shortcut phrase on macOS 27 (§3), starting with the two
   unchecked settings.

**Possible additions**
3. Mac: report the sidebar selection (SelectFeed activity) so feeds resolve as "this" too. That's Mac
   UI code outside `ActivityManager`.
4. Folder and smart-feed entities for the SelectFeed annotation (currently only `Feed` is tagged).
5. Remaining plan items:
   - `.system` schema intents: in-app search ("search NetNewsWire for X") and open article/feed. These
     reach Siri and Apple Intelligence.
   - Plain intents with phrases: Refresh (background), unread count (`ReturnsValue<Int>` plus a dialog,
     optionally a `SnippetIntent`), Show Today / All Unread / Starred, Mark All as Read (confirm with
     `requestConfirmation` first), Star / Mark Read on "this" (`UndoableIntent`).
   - Spotlight: make `FeedEntity` / `ArticleEntity` `IndexedEntity`. The Mac indexes no articles
     today; `ActivityManager`'s indexing is iOS-only. On 27, use `relatedAppEntityIdentifier` and
     `IndexedEntityQuery`.
   - Tests with `AppIntentsTesting` (27); they run against the installed app.
6. Optional: a "Read Article Aloud" intent built on `ArticleEntity`'s text, since Siri won't read it.

**Upstream prep**
7. Squash the six commits, strip trailers, and target `upstream/main`. Send `90b488e3d` as a separate
   small PR.

Skip for now: `RelevantEntities` (audio only), Visual Intelligence (weak fit), `SyncableEntity`
(entity IDs embed per-device account IDs), and the `reader` / `browser` schemas (Shortcuts-only, not
Siri).

---

## 7. Environment gotchas

- **Duplicate actions in Shortcuts** come from Debug copies registered with Launch Services. They have
  the same app name and intents, and they never work (`SKIP_APP_GROUP_ACCESS`). Unregister them with
  `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u <path to .app>`.
  - `dave-install.sh` now does this for its test host on Release installs.
  - Xcode Debug builds and runs re-register their copy.
- **The Shortcuts action index** is at `~/Library/Shortcuts/ToolKit/Tools-prod.v*.sqlite`:
  ```
  sqlite3 -readonly <db> "select c.id, c.bundleVersion, t.id from Tools t join ContainerMetadata c on c.rowId=t.sourceContainerId where c.id like '%NetNewsWire%';"
  ```
- **App Intents execution logs** (subsystem `com.apple.appintents`, in the NetNewsWire process) show
  each `perform()`. NetNewsWire's own errors are in `~/Library/Application Support/NetNewsWire/Errors.db`
  (`errors` table; `date` is seconds since 2001).
- **In the Claude Code Bash tool (zsh), `log` is a shell builtin.** Use **`/usr/bin/log show …`**.
- **The personal Mac app is unsandboxed** (`-dev` entitlements). Its data is in
  `~/Library/Application Support/NetNewsWire/`, not `~/Library/Containers`.
- **`dave-install.sh` is interactive** (gum), so it can't run via `!` or a non-TTY shell.
- **Builds:** quit Xcode before rebasing. Worktrees need a `SharedXcodeSettings` symlink in their
  parent directory and a throwaway first build. Mac compile checks need `CODE_SIGNING_ALLOWED=NO`. Use
  `generic/platform=iOS Simulator` for iOS build-only checks.
- **xcstrings churn:** a build after adding localized strings can rewrite `Shared/Localizable.xcstrings`.
  This work's builds didn't, but check `git status` before committing.
