# CLAUDE.md — Plezy (with VIDYA support)

> Last updated: 2026-06-17 — Post-Phase-1a bug fix session (Round 1–3 diagnosis)

---

## What this project is

**Plezy** is a Flutter app for Android TV / Google TV that streams media from Plex and Jellyfin servers. It uses the **media_kit** package (MPV) for Plex/Jellyfin video playback.

**VIDYA** is a separate self-hosted course platform (like Udemy) added as a first-class backend alongside Plex and Jellyfin. VIDYA has its own video player, completely separate from the MPV player.

---

## Critical architecture decision: two separate video players

- **Plex / Jellyfin** → `VideoPlayerScreen` → MPV via `media_kit` / `Video` widget
- **VIDYA** → `VidyaCoursePlayerView` → ExoPlayer via the `video_player` Flutter plugin

**Why separate?** MPV renders to a native Android `SurfaceView` that bypasses Flutter layout constraints — `Expanded`/`AnimatedPadding` constrains the Flutter widget box but the actual video surface bleeds through full-screen. The `video_player` plugin uses a `Texture` widget that genuinely respects Flutter layout bounds, required for the VIDYA split layout.

**Never route VIDYA lectures through `VideoPlayerScreen` or MPV.** They must go through `VidyaCoursePlayerView`.

---

## VIDYA player layout (`VidyaCoursePlayerView`)

```
┌────────────────────────────────────────────┬────────────────────┐
│  VIDEO CANVAS  (flex:4 when sidebar open,  │  Course Sidebar    │
│  full width when closed)                   │  (flex:1, toggle)  │
│                                            │                    │
│  [Course › Section › Lesson]  ← breadcrumb│  § Section 1       │
│                                            │    ✓ Lesson 1.1    │
│  Controls overlay (auto-hides 4 s):        │    ▶ Lesson 1.2 ◄  │
│    [←10]  [▶/⏸]  [10→]  ══════  0:00     │    ○ Lesson 1.3    │
│                                            │    📎 notes.pdf    │
└────────────────────────────────────────────┴────────────────────┘
Sidebar attachments are wrapped in ExcludeFocus — D-pad skips them.
```

## D-pad / controller navigation (`VidyaCoursePlayerView`)

| Key | Context | Action |
|-----|---------|--------|
| Right | Video area | Opens sidebar + shifts focus to it |
| Left | Sidebar | Closes sidebar + returns focus to video |
| Back/Escape | Sidebar | Same as Left |
| Down | Video area | Forces controls overlay visible (progress bar) |
| Up | Video area | Hides controls overlay |
| Select / Space | Video area | Play / Pause |
| Left arrow | Video area | Seek −10 s |
| Right arrow (sidebar closed) | Video area | Seek +10 s |
| Back/Escape | Video area | Exit screen |
| Select | Sidebar lesson | Switch to that lesson + close sidebar |

- Currently-playing lesson: `#A435F0` at 28% opacity row tint + `play_circle_rounded` icon
- Completed lesson: green `check_circle_rounded` icon
- Incomplete lesson: `radio_button_unchecked_rounded` icon

## Auto-advance (next lesson)

When `videoPosition ≥ videoDuration − 500 ms`:
1. Current lesson marked complete in local outline state (checkmark appears immediately)
2. Next `type == 'video'` lesson in the flat lesson list is found
3. `_switchLesson()` disposes the old controller and starts the new stream
4. Focus stays in the video area

---

## Progress tracking (`VidyaPlaybackTracker`)

`lib/services/vidya_progress_tracker.dart` — **completely isolated, no Plex/Jellyfin imports.**

- Attaches to a `VideoPlayerController` via `attach(ctrl, lectureId: id)`
- **15 s heartbeat** — `Timer.periodic`, fires only while `isPlaying == true`
- **Immediate sync on pause** — detected via `addListener`
- **Immediate sync on completion** — detected when `position ≥ duration − 500 ms`
- **Offline queue** — failures serialized to `SharedPreferences` under `vidya_offline_sync_queue`; flushed automatically after every successful sync
- **`SharedPreferences` instance is cached** via `_getPrefs()` — obtained once per tracker lifetime, not on every timer tick
- Call `detach()` in `dispose()` to cancel timer and remove listener
- Call `attach()` again when lecture changes; old listener/timer cleaned up automatically

---

## Key files

| File | Purpose |
|------|---------|
| `lib/screens/vidya_course_player_view.dart` | **Current** VIDYA player — Udemy-style split layout, sidebar, auto-next |
| `lib/screens/vidya_course_browser_screen.dart` | Course browser → pushes `VidyaCoursePlayerView` |
| `lib/services/vidya_api_client.dart` | HTTP client: `VidyaApiClient` (session-scoped) + `VidyaBrowseClient` (browse + outline) |
| `lib/services/vidya_connection.dart` | `VidyaPlaybackSession` model |
| `lib/services/vidya_progress_tracker.dart` | Heartbeat tracker + offline queue |
| `lib/connection/connection.dart` | `VidyaAccountConnection` sealed class |
| `lib/screens/settings/add_vidya_screen.dart` | Add-connection form → `POST /api/auth/token` |
| `lib/services/vidya_media_server_client.dart` | `MediaServerClient` stub for VIDYA — wires into `DataAggregationService` for home screen |
| `lib/services/vidya_token_manager.dart` | JWT auto-refresh wrapper; `fromConnection(conn, registry)` for browse/home; `fromSession(session)` for player |
| `lib/services/multi_server_manager.dart` | `addVidyaConnection(conn, registry)` / `removeVidyaConnection(conn)`; VIDYA offline-recovery timer |
| `lib/profiles/active_profile_binder.dart` | `_bindVidya(conn)` called for `VidyaAccountConnection` on profile activation |
| `lib/utils/media_navigation_helper.dart` | VIDYA intercept before kind-switch: episode → player with resume, show → course browser |
| `lib/screens/video_player_screen.dart` | Plex/Jellyfin MPV player; `_pauseAndHidePlayerForRouteExit()` helper |
| `lib/widgets/video_controls/parts/navigation.dart` | `_buildDesktopControlsListener()`; uses `context.read` (not `context.watch`) for VidyaSessionProvider |
| `lib/widgets/video_controls/parts/visibility.dart` | `_reclaimFocusAfterControlsHide()` focus reclaim; must stay two-shot (see below) |
| `android/app/build.gradle.kts` | Release signing fallback + `extractMpvLibcxx` Windows fix |

---

## VIDYA API endpoints used by Plezy

| Endpoint | Client method | Notes |
|----------|---------------|-------|
| `POST /api/auth/token` | `AddVidyaScreen` directly | Returns `{ token, user }` |
| `GET /api/course` | `VidyaBrowseClient.fetchCourses()` | All courses list |
| `GET /api/course/:courseId` | `VidyaBrowseClient.fetchCourseDetail()` | Course + sections + lectures (no progress) |
| `GET /api/v1/home` | `VidyaMediaServerClient.fetchContinueWatching()` / `fetchGlobalHubs()` | Home screen data: in-progress lectures + all courses hub |
| `GET /api/v1/courses/:courseId/outline` | `VidyaBrowseClient.fetchOutline()` | Course + sections + lessons + per-user progress + attachments |
| `GET /api/course/stream/:lectureId?token=` | Stream URL passed to `VideoPlayerController.networkUrl()` | Range requests, token in query string |
| `POST /api/course/player` | `VidyaApiClient.fetchCourseWithContent()` | Includes `content` array per lecture |
| `GET /api/course/uploads/:lectureId` | `VidyaApiClient.fetchUploads()` | User uploads list |
| `DELETE /api/course/uploads/:uploadId` | `VidyaApiClient.deleteUpload()` | Delete user upload |
| `POST /api/v1/progress/sync` | `VidyaApiClient.syncProgress()` / `VidyaPlaybackTracker` | `{ course_id, lesson_id, time_seconds, is_completed }` |

**Stream URL pattern:** `${baseUrl}/api/course/stream/${lectureId}?token=${token}` — no auth header needed (`verifyQueryToken` middleware).

---

## VIDYA connection model

```
VidyaAccountConnection (persisted in Drift `connections` table, kind = 'vidya')
  ├── id          "vidya-{uuid}"
  ├── baseUrl     "http://192.168.x.x:31415"
  ├── serverName  derived from URL authority
  ├── userId      from auth response
  ├── userName    from auth response
  └── accessToken JWT (1 h TTL; refresh via /api/auth/refresh)

VidyaPlaybackSession (ephemeral, in-memory only)
  ├── baseUrl
  ├── token                = VidyaAccountConnection.accessToken
  ├── courseId
  ├── lectureId
  └── resumePositionSeconds  (seconds to seek on first load; 0 = start from beginning)
```

---

## Home screen caching (`VidyaMediaServerClient`)

`_fetchHome()` fetches `GET /api/v1/home` and serves both `fetchContinueWatching()` and `fetchGlobalHubs()`. To prevent two serial HTTP requests per home refresh cycle:

- **30-second TTL cache** — `_homeCache` / `_homeCacheTime`; hits return immediately with no network activity
- **In-flight deduplication** — `_pendingHomeFetch`; concurrent callers share the same `Future` rather than firing parallel requests

Do not call `_fetchHome()` directly outside of `fetchContinueWatching()` / `fetchGlobalHubs()`.

**`serverName` live-cache override (Phase 1a):** The `serverName` getter first reads `_homeCache?['server_name']`; falls back to URL-authority string only on cold boot before the first home fetch. The `server_name` string is populated by `GET /api/v1/home` on the VIDYA backend.

---

## Discover screen — Vidya row ordering (Phase 1a)

`lib/screens/discover_screen.dart` renders Vidya rows in a completely separate section below all Plex/Jellyfin content. The filter key is `item.serverId?.startsWith('vidya-')` (and `hub.serverId?.startsWith('vidya-')`), matching `VidyaAccountConnection.id = "vidya-{uuid}"`.

**Rendered order (both TV and non-TV paths):**
1. Non-Vidya "Continue Watching" row (`_continueWatchingHubKey`) — Vidya items filtered out
2. Non-Vidya recommendation hubs
3. "Continue Learning" row (`_vidyaContinueLearningHubKey`) — Vidya in-progress items only
4. Vidya content hubs (e.g. "All Courses")

**State fields added:**
- `_vidyaContinueLearningHubKey` — `GlobalKey<HubSectionState>?`, initialized in `_updateHubKeys()`
- `_hasVidyaOnDeck` — **getter** (not a field): `bool get _hasVidyaOnDeck => _onDeck.any((item) => item.serverId?.startsWith('vidya-') == true)` — the stale field assignment was removed from `_updateHubKeys()`; the getter is evaluated on each build

**`_allHubKeys` ordering:** `[non-Vidya CW?] → [non-Vidya hubs] → [Vidya CL?] → [Vidya hubs]` — must match the visual render order exactly for D-pad `_handleVerticalNavigation` index arithmetic to be correct.

**Navigation index precomputation (in `_buildContent()`):**
```dart
final cwNavIdx = nonVidyaOnDeck.isNotEmpty ? 0 : -1;
final nonVidyaHubNavStart = nonVidyaOnDeck.isNotEmpty ? 1 : 0;
final vidyaClBase = nonVidyaHubNavStart + nonVidyaHubIndices.length;
final vidyaClNavIdx = vidyaOnDeck.isNotEmpty ? vidyaClBase : -1;
final vidyaHubNavStart = vidyaClBase + (vidyaOnDeck.isNotEmpty ? 1 : 0);
```

**`loadMoreItems` filter:** The "load all" callback for the Continue Watching row wraps `_discover.loadAllContinueWatching()` with a `.where((item) => item.serverId?.startsWith('vidya-') != true)` filter to prevent Vidya items reappearing after pagination.

**Icon:** Vidya rows use `Symbols.school_rounded`; Continue Learning has `isInContinueWatching: true` for progress overlays.

---

## Discover screen — known issue: `_applyOnDeck` wholesale replacement

`lib/providers/discover_provider.dart` — `refreshContinueWatching()`.

`_applyOnDeck(fetched)` replaces `_onDeck` entirely. When a background Plex refresh returns no VIDYA items (VIDYA is slow to respond or temporarily offline), all VIDYA entries are evicted and `vidyaOnDeck.isNotEmpty` becomes false, removing the "Continue Learning" row from the widget tree.

**Pending fix:** protective merge — preserve existing VIDYA items from `_onDeck` when `fetched` contains zero VIDYA items:
```dart
final freshVidya = fetched.where((i) => i.serverId?.startsWith('vidya-') == true).toList();
final merged = freshVidya.isNotEmpty
    ? fetched
    : [...fetched, ..._onDeck.where((i) => i.serverId?.startsWith('vidya-') == true)];
_applyOnDeck(merged);
```

---

## Video controls — focus reclaim (`visibility.dart`)

`lib/widgets/video_controls/parts/visibility.dart` — `_reclaimFocusAfterControlsHide()`.

Called from `_onChromeChanged()` whenever controls hide. Must return focus to `_focusNode` so D-pad Back reaches the route-exit handler. The correct pattern is **two-shot**:

```dart
void _reclaimFocusAfterControlsHide() {
  final sheetOpen = OverlaySheetController.maybeOf(context)?.isOpen ?? false;
  if (sheetOpen) return;
  _focusNode.requestFocus();
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted && !_focusNode.hasPrimaryFocus) {
      _focusNode.requestFocus();
    }
  });
}
```

**Bug (Round 2 regression):** A third `addPostFrameCallback` was nested unconditionally inside shot #2. Shot #3 fires regardless of whether shot #2 successfully reclaimed focus, creating an infinite hide→reclaim→hide cycle. Controls lock permanently visible; back button never reaches its route-pop handler. Fix: remove the nested callback. Pending authorization.

**`context.read` guard (`navigation.dart` line 11):** `context.watch<VidyaSessionProvider>()` registered the entire `PlexVideoControls` widget as a listener to `VidyaSessionProvider`. Background VIDYA token validation fires `notifyListeners()` during Plex playback, causing full rebuilds that race with focus reclaim. Fixed: changed to `context.read<VidyaSessionProvider>()`.

---

## VIDYA server offline recovery (`multi_server_manager.dart`)

`lib/services/multi_server_manager.dart` — `_vidyaRetryTimer`.

When VIDYA health check fails at startup, `_serverStatus[id]` is set to `false`, gating VIDYA out of `onlineClients` and the entire home screen. A `Timer.periodic(30 s)` retry loop started by `_scheduleVidyaRetryIfNeeded()`:
- Called from `addVidyaConnection()` after the initial health check fails
- Polls all offline VIDYA clients every 30 s; calls `_applyHealth()` on each
- Cancels itself once all VIDYA clients come online
- Cancelled by `_detachAllClients()` on teardown

---

## Android TV / release APK build

**Target device:** onn Streaming Device 4K Pro (API 34, armeabi-v7a 32-bit runtime despite 64-bit CPU).

**JAVA_HOME:** `C:\Program Files\Android\Android Studio\jbr`

**Build command (fat APK — required):**
```
flutter build apk --release --target-platform android-arm,android-arm64
```
`android-arm64`-only APK crashes at launch with `Could not find 'libflutter.so'. Looked for: [armeabi-v7a, armeabi], but only found: [arm64-v8a]`. Always build fat.

**ADB install:** Use SDK ADB at `C:\Users\josh\AppData\Local\Android\Sdk\platform-tools\adb.exe -t 1` (transport_id 1 for the mDNS wireless device). The Tiny ADB in `PATH` does **not** see mDNS-discovered devices.

**`build.gradle.kts` signing fix:** Newer AGP does not auto-fall-back to debug signing when `key.properties` is absent. Explicit fallback:
```kotlin
signingConfig = if (keystorePropertiesFile.exists()) {
  signingConfigs.getByName("release")
} else {
  signingConfigs.getByName("debug")
}
```
Without this, the release APK installs with `INSTALL_PARSE_FAILED_NO_CERTIFICATES`.

**`extractMpvLibcxx` task fix:** The original task used `commandLine("unzip", ...)` which fails in the Windows JVM context (no `unzip` on `PATH`). Fixed with Gradle-native zip extraction:
```kotlin
doLast {
  outDir.deleteRecursively()
  project.copy {
    from(project.zipTree(aar)) {
      include("jni/*/libc++_shared.so")
    }
    into(outDir)
  }
}
```

---

## Plex/Jellyfin player back-button (`video_player_screen.dart`)

`lib/screens/video_player_screen.dart` — `_pauseAndHidePlayerForRouteExit()`.

The fork was missing this helper. Without it, the MPV surface remains visible when navigating back from the player screen. Must be called in `_handleBackButton()` for both the Watch Together exit branch and the default exit branch:

```dart
Future<Duration?> _pauseAndHidePlayerForRouteExit() async {
  final currentPlayer = player;
  if (currentPlayer == null || !_isPlayerInitialized) return null;
  final exitPosition = currentPlayer.state.position;
  if (currentPlayer.state.isActive) {
    try { await currentPlayer.pause(); } catch (e, st) { ... }
  }
  if (!mounted || currentPlayer != player) return exitPosition;
  if (Platform.isAndroid && PlatformDetector.isTV()) {
    try { await currentPlayer.setVisible(false); } catch (e, st) { ... }
  }
  return exitPosition;
}
```

The result is passed as `positionOverride` to `_sendStoppedProgressOnce`.

---

## Connection cleanup (`profile_connection_cleanup.dart`)

`lib/profiles/profile_connection_cleanup.dart` provides startup and settings-screen utilities for pruning orphaned Jellyfin connections and clearing stale per-server library preferences.

- `pruneUnreferencedJellyfinConnections()` — called at every startup from `_SetupScreenState._loadSavedCredentials()` after `ConnectionBootstrap.run()`
- `removeProfileConnectionAndCleanup()` — called from profile detail screen when removing a connection
- `removeAllProfileConnectionsAndCleanup()` — called from profile delete flow
- The sealed switch in `_serverIdsForConnection()` includes a `VidyaAccountConnection() => const {}` arm — Vidya connections carry no library preferences

`StorageService` exposes `clearLibraryPreferencesForServer()` and `clearLibraryPreferencesForServerEverywhere()` which these functions depend on.

---

## Pointer event guard (`main.dart`)

`_installZeroOffsetPointerGuard()` is an iOS/tvOS-only workaround for Flutter bug #177992 (iPadOS 26.1+ fake touch events at `(0,0)` dismissing modals). The guard **must remain iOS-only**:

```dart
// CORRECT — iOS only, PointerDownEvent only
void _installZeroOffsetPointerGuard() {
  if (_zeroOffsetPointerGuardInstalled || !Platform.isIOS) return;
  ...
}
void _absorbZeroOffsetPointerEvent(PointerEvent event) {
  if (event is PointerDownEvent && event.position == Offset.zero) { ... }
}
```

Never remove `!Platform.isIOS` or the `event is PointerDownEvent` type check. Doing so causes all pointer events at `Offset.zero` to be dropped globally on Android TV, causing intermittent D-pad input loss on Plex and Jellyfin screens.

---

## CI / build

- GitHub Actions builds APK on every push to `main`
- `video_player: ^2.9.2` is in `pubspec.yaml` (used for VIDYA)
- `android:usesCleartextTraffic="true"` is set in AndroidManifest — HTTP VIDYA servers work
- **Local compilation requires:** JDK 17 (`C:\Program Files\Android\Android Studio\jbr`) + Android SDK CLI tools. See "Android TV / release APK build" section above.

## Platform target

- Primary: **Android TV / Google TV** (D-pad / controller input, no touch)
- VIDYA server is self-hosted, accessed over local network (HTTP)

## Audit

A full regressive audit was conducted on 2026-06-16 comparing this fork against the original plezy repository. See `audit.md` for complete findings. Four performance regressions were identified and fixed in commit `df2c3047`.
