# Plezy — Roadmap

> Last updated: 2026-06-17 — Post-Phase-1a bug fix session (Round 1–3; two fixes pending)

---

## Project Directories

| Directory | Purpose |
|-----------|---------|
| `C:\Users\josh\Projects\plezy` | Plezy Flutter app (this project) |
| `C:\Users\josh\Projects\vidya` | VIDYA backend server |
| `C:\Users\josh\Projects\Flutter` | Flutter SDK (reference only — do not modify) |

---

## Phase Status

| Phase | Status | Summary |
|-------|--------|---------|
| Initial VIDYA Integration | ✅ Complete | VidyaAccountConnection, browser, legacy player |
| Feature Vertical 2 | ✅ Complete | VidyaPlaybackTracker — heartbeat + offline queue |
| Feature Vertical 3 | ✅ Complete | VidyaCoursePlayerView — Udemy-style split player |
| Feature Vertical 4 | ✅ Complete | VIDYA courses on home screen — JWT auto-refresh, MediaServerClient, home endpoint |
| Performance Regression Audit | ✅ Complete | Full regressive audit vs original repo; 4 regressions identified and fixed (see `audit.md`) |
| Phase 1a — Home Screen Rewiring & Server Naming | ✅ Complete | Dedicated Vidya rows on Discover screen; custom server name API + admin UI |
| Post-Phase-1a Bug Fixes | 🔄 In Progress | 4 of 6 fixes landed; 2 pending (visibility.dart loop, discover_provider merge) |

---

## Initial VIDYA Integration `complete`

- [x] `VidyaAccountConnection` — sealed `Connection` subclass, persisted in Drift `connections` table with `kind = 'vidya'`
- [x] `AddVidyaScreen` — server URL + credentials form; calls `POST /api/auth/token`; stores token
- [x] `VidyaBrowseClient` — unauthenticated-by-session HTTP client for pre-playback browsing (`fetchCourses`, `fetchCourseDetail`)
- [x] `VidyaCourseBrowserScreen` — two-level browser (courses → sections → lectures); grid card layout
- [x] `VidyaApiClient` — session-scoped HTTP client (`fetchCourseWithContent`, `fetchUploads`, `deleteUpload`)
- [x] `VidyaPlayerScreen` — original player with `video_player` (ExoPlayer); in-player tabs (Course Content + User Uploads) via `vidya_course_panel.dart`; `ExcludeFocus` on attachment list items
- [x] `VidyaPlaybackSession` — ephemeral in-memory session model (baseUrl, token, courseId, lectureId)
- [x] Stream URL via `GET /api/course/stream/:lectureId?token=` — no auth header; `verifyQueryToken` middleware on server
- [x] `ConnectionKind.vidya` wired into connection picker and home screen alongside Plex/Jellyfin

---

## Feature Vertical 2 — Progress Syncing & Heartbeat `complete`

### Server (Vidya)
- [x] `POST /api/v1/progress/sync` — accepts `{ course_id, lesson_id, time_seconds, is_completed }`; upserts `LectureProgress` (progress 0–100 derived from duration, never regresses via MAX); latches `hasCompleted` permanently; updates `CourseProgress` pointer to last-watched lecture
- [x] Route file `backend/routes/v1.js` mounted at `app.use("/api/v1", v1Routes)` in `backend/index.js`

### Client (Plezy)
- [x] `VidyaPlaybackTracker` (`lib/services/vidya_progress_tracker.dart`)
  - Zero Plex/Jellyfin imports
  - Attaches to `VideoPlayerController` via `attach(ctrl, lectureId: id)`
  - 15 s `Timer.periodic` heartbeat — only fires when `isPlaying == true`
  - Immediate sync on pause (detected via `addListener`)
  - Immediate sync on completion (detected when `position ≥ duration − 500 ms`)
  - Offline queue in `SharedPreferences` under key `vidya_offline_sync_queue`
  - Auto-flushes offline queue after every successful sync
  - `detach()` cancels timer + removes listener; safe to call in `dispose()`
  - `attach()` can be called again on lecture switch — auto-cleans previous listener/timer
- [x] `VidyaApiClient.syncProgress()` — `POST /api/v1/progress/sync`
- [x] `VidyaBrowseClient.fetchOutline()` — `GET /api/v1/courses/:courseId/outline`

---

## Feature Vertical 3 — Udemy-Style Player `complete`

### Server (Vidya)
- [x] `GET /api/v1/courses/:course_id/outline` — returns full course structure (sections → lessons) with per-user `is_completed`, `progress`, `watch_time`, and `attachments` array per lesson

### Client (Plezy)
- [x] `VidyaCoursePlayerView` (`lib/screens/vidya_course_player_view.dart`)
  - Standalone screen — zero shared code with Plex/Jellyfin player (`VideoPlayerScreen`)
  - Uses `video_player` plugin (ExoPlayer on Android) — respects Flutter layout constraints unlike MPV
  - **80/20 split layout**: video + controls (flex:4) left; toggleable course sidebar (flex:1) right
  - **Breadcrumb overlay**: `Course › Section › Lesson`
  - **Controls overlay** (auto-hides 4 s): `←10s` / `▶⏸` / `10s→` / `LinearProgressIndicator` / timestamp
  - **D-pad Right** from video → opens sidebar + shifts focus; **Left** from sidebar → closes + returns to video
  - **D-pad Down** from video → reveals controls overlay; **Up** → hides overlay
  - **D-pad Select** → play/pause; **Left** in video → seek −10 s; **Back/Escape** → exit screen
  - Sidebar: section headers non-focusable (`ExcludeFocus`), lesson tiles focusable with ✓/▶/○ status icons
  - Currently-playing lesson: `#A435F0` 28% opacity tint + `play_circle_rounded` icon
  - Completed lessons: green `check_circle_rounded` icon
  - Attachments listed under current lesson in `ExcludeFocus` — D-pad skips them entirely
  - **Auto-advance**: on "Media Ended" → marks complete locally → finds next `type == 'video'` lesson in flat list → `_switchLesson()` (dispose old controller, reinit new stream) → focus stays in video area
  - Outline fetch (`fetchOutline`) and video init run concurrently via `unawaited()`; sidebar shows spinner until outline arrives
- [x] `VidyaCourseBrowserScreen` updated to push `VidyaCoursePlayerView` (old `VidyaPlayerScreen` file untouched — kept as reference)

---

## Feature Vertical 4 — Test Checklist

### Home screen
- [ ] VIDYA courses appear in a "Continue Watching" row (lectures started but not finished)
- [ ] VIDYA courses appear in a hub row (all courses)
- [ ] Thumbnails load correctly
- [ ] Plex/Jellyfin rows are unaffected

### Navigation from home screen
- [ ] Tapping a course hub item (show) → opens `VidyaCourseBrowserScreen`
- [ ] Tapping a continue-watching lecture (episode) → opens `VidyaCoursePlayerView` directly
- [ ] Resume position: a mid-way lecture seeks to where you left off

### Player regression
- [ ] Playback starts correctly
- [ ] Sidebar opens/closes with D-pad Right/Left
- [ ] Auto-advance to next lecture works
- [ ] Progress syncs back to the server (heartbeat + on pause)

### Edge cases
- [ ] No VIDYA server added → home screen shows only Plex/Jellyfin, no crash
- [ ] VIDYA server offline → home screen loads gracefully, other backends still work
- [ ] Token expired → auto-refresh fires and content loads after re-auth

### Plex/Jellyfin regression
- [ ] Home screen rows, playback, and navigation unchanged
- [ ] Plex/Jellyfin items unaffected by VIDYA intercept in `media_navigation_helper.dart`

---

## Performance Regression Audit `complete`

> Full findings in `audit.md`. All four priorities fixed in commit `df2c3047`.

- [x] **P1** — Restore iOS-only platform guard + `PointerDownEvent` type check in `main.dart` pointer absorber (was silently dropping all pointer events at `Offset.zero` on Android TV)
- [x] **P2** — Add 30-second TTL cache + in-flight deduplication to `VidyaMediaServerClient._fetchHome()` (was firing two serial uncached HTTP requests per home refresh)
- [x] **P3** — Restore `profile_connection_cleanup.dart` and startup `pruneUnreferencedJellyfinConnections()` call; port missing `StorageService` server-cleanup helpers (`clearLibraryPreferencesForServer`, `clearLibraryPreferencesForServerEverywhere`, 8 private helpers)
- [x] **P4** — Cache `SharedPreferences` instance in `VidyaPlaybackTracker` via `_getPrefs()` (was calling `SharedPreferences.getInstance()` on every 15-second timer tick during network failure)
- [x] **Backlog** — Redundant `fetchCourseWithContent()` in `VidyaLectureResources` + `VidyaCoursePanel` resolved by deleting the dead files entirely

---

---

## Phase 1a — Home Screen Rewiring & Server Naming `complete`

### Discover Screen (Plezy — `lib/screens/discover_screen.dart`)
- [x] **Option B clean separation**: Vidya in-progress items filtered OUT of standard "Continue Watching" row; appear exclusively in the new "Continue Learning" row
- [x] **"Continue Learning" row**: dedicated `HubSection` at the bottom of the non-TV path; `TvBrowseRail` hub appended last on TV path; uses `Symbols.school_rounded` icon; `isInContinueWatching: true` for progress overlays
- [x] **Vidya hubs last**: Vidya "All Courses" hub (and any future Vidya hubs) rendered below Continue Learning, after all non-Vidya recommendation hubs
- [x] **`_allHubKeys` reordered**: `[non-Vidya CW?] → [non-Vidya hubs] → [Vidya CL?] → [Vidya hubs]` — D-pad up/down navigation correctly traverses all rows on both TV and mobile
- [x] **`_tvBrowseHubs` reordered**: same ordering for the TV `TvBrowseRail`, including `isContinueWatchingHub` for both `continue_watching` and `continue_learning`
- [x] **`loadMoreItems` filter**: "load all" callback for continue_watching filters Vidya items from result to prevent mixing

### Course Artwork (Plezy — `lib/services/vidya_media_server_client.dart`)
- [x] `_courseToMediaItem` kind changed `MediaKind.show → MediaKind.movie` — course thumbnails now render as 16:9 landscape banners matching Vidya's photo aspect ratio; navigation unaffected (intercepted by backend check before kind-switch)

### Server Naming — Backend (Vidya)
- [x] `GET /api/v1/home`: includes `server_name` key in response payload (sourced from `Server.name` in SQLite)
- [x] `POST /api/admin/server-name`: new admin route to update `Server.name`; validates non-empty body
- [x] `GET /api/admin/admin`: `getAdminData` now fetches `Server.findOne()` in the same `Promise.all` and returns `serverName` in the response

### Server Naming — Admin UI (Vidya — `src/components/Settings/Admin.js`)
- [x] "Server Name" text input + Save button added at the top of Admin Settings, above Folders
- [x] Loads current name from `getAdminData` response on mount; saves via `POST /api/admin/server-name`

### Server Naming — Client Bridge (Plezy — `lib/services/vidya_media_server_client.dart`)
- [x] `serverName` getter reads live `server_name` from the home cache; falls back to URL-authority string on cold boot (before first home fetch)

---

## Post-Phase-1a Bug Fixes `in progress`

> Three diagnostic rounds on device (onn 4K Pro, wireless ADB). Bugs diagnosed after APK install and live testing.

### Build System (completed)
- [x] **`build.gradle.kts` release signing fallback** — Newer AGP no longer auto-falls-back to debug signing when `key.properties` absent; explicit `signingConfigs.getByName("debug")` fallback added. Fixed `INSTALL_PARSE_FAILED_NO_CERTIFICATES`.
- [x] **`extractMpvLibcxx` Windows fix** — `commandLine("unzip", ...)` fails in Windows JVM (no `unzip` on PATH). Replaced with `project.copy { from(project.zipTree(aar)) { include("jni/*/libc++_shared.so") } into(outDir) }`.
- [x] **Fat APK ABI targeting** — Device loads 32-bit armeabi-v7a despite 64-bit hardware. Build must include `--target-platform android-arm,android-arm64`.

### Back-Button Regression — Round 1 (completed)
- [x] **`_pauseAndHidePlayerForRouteExit()` restored** (`lib/screens/video_player_screen.dart`) — Fork was missing this helper. Without it, the MPV surface stays visible on back-navigation. Both Watch Together exit and default exit branches in `_handleBackButton()` now call this helper.

### Focus Reclaim — Round 2 (completed, but introduced regression)
- [x] **`context.watch` → `context.read`** (`lib/widgets/video_controls/parts/navigation.dart` line 11) — Background VIDYA token validation fires `notifyListeners()` during Plex playback, causing spurious rebuilds of `PlexVideoControls` that race with focus reclaim.
- [x] **VIDYA health-check recovery timer** (`lib/services/multi_server_manager.dart`) — `_vidyaRetryTimer`: `Timer.periodic(30 s)` polls offline VIDYA clients and re-applies health status on recovery.
- [⚠️] **Three-shot `_reclaimFocusAfterControlsHide()`** (`lib/widgets/video_controls/parts/visibility.dart`) — Added a third nested `addPostFrameCallback` that fires unconditionally, creating an infinite hide→reclaim→hide loop. Controls lock visible permanently; back button breaks.

### Continue Learning Row — Round 2 (completed, but not root cause)
- [x] **`_hasVidyaOnDeck` converted from field to getter** (`lib/screens/discover_screen.dart`) — Correct change, but not the cause of row disappearance.
- [x] **`AutomaticKeepAliveClientMixin`** (added in Round 1, reverted in Round 2) — `SliverToBoxAdapter` does not support keepAlive; mixin was ineffective.

### Pending Fixes (awaiting implementation)

- [ ] **Fix `_reclaimFocusAfterControlsHide()` infinite loop** (`lib/widgets/video_controls/parts/visibility.dart`) — Remove nested shot #3 (lines 295–298). Revert to two-shot pattern.

- [ ] **Fix Continue Learning row displacement** (`lib/providers/discover_provider.dart`) — `_applyOnDeck(fetched)` wholesale-replaces `_onDeck`; VIDYA items evicted when background Plex refresh returns no VIDYA data. Fix: preserve existing VIDYA items when fresh fetch returns none.

---

## Future / Backlog

- Token refresh flow in `VidyaApiClient` — refresh JWT automatically when 401 received during playback
- D-pad seek-bar scrubbing — hold Left/Right to skip in larger increments
- Subtitle track selection for VIDYA lectures (SRT → WebVTT served by server)
- Resume-from-last-position on launch — use `watch_time` from outline to seek on `_initVideo`
- Connection health check / reconnect screen on network loss mid-playback
- ~~Eliminate dead code: `VidyaPlayerScreen`, `VidyaCoursePanel`, `VidyaLectureResources`~~ — Done
