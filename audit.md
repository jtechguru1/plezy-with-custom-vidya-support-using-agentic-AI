# Plezy — Regressive Audit Report

> Conducted: 2026-06-16
> Auditor: Claude Sonnet 4.6 (agentic)
> Baseline: `C:\Users\josh\Projects\original repos\plezy-main`
> Subject: `C:\Users\josh\Projects\plezy` (custom fork with VIDYA support)
> Commit at time of audit: `ac004a60`
> Fixes applied in commit: `df2c3047`

---

## Purpose

A performance bottleneck was suspected to have been introduced during the initial VIDYA integration. This audit compared every modified file in the fork against the original plezy repository to:

1. Verify all foundational plezy code was strictly maintained
2. Identify any VIDYA-specific code with structural performance problems
3. Confirm Vidya features were added as additive extensions, not destructive overrides

---

## Section 1 — File Structure Changes

### Files present in original but MISSING from fork (before fixes)

| File | Impact |
|------|--------|
| `lib/profiles/profile_connection_cleanup.dart` | Startup prune of orphaned Jellyfin connections no longer ran; stale connection state accumulated silently |
| `lib/services/device_adjustment_service.dart` | Device-specific tuning removed |
| `lib/widgets/video_controls/helpers/mobile_edge_adjustment_tracker.dart` | Mobile swipe tracking removed |
| `lib/widgets/video_controls/widgets/mobile_edge_adjustment_indicator.dart` | Mobile swipe UI removed |

> **Status:** `profile_connection_cleanup.dart` restored in fix commit `df2c3047`. The remaining three are intentional removals (mobile-only features not relevant to TV target).

### New files added by VIDYA integration (expected additions)

- `lib/providers/vidya_session_provider.dart`
- `lib/screens/vidya_course_browser_screen.dart`
- `lib/screens/vidya_course_player_view.dart`
- `lib/screens/vidya_player_screen.dart` *(dead code — not reachable from any navigation path)*
- `lib/screens/settings/add_vidya_screen.dart`
- `lib/services/file_log_service.dart`
- `lib/services/vidya_api_client.dart`
- `lib/services/vidya_connection.dart`
- `lib/services/vidya_media_server_client.dart`
- `lib/services/vidya_progress_tracker.dart`
- `lib/services/vidya_token_manager.dart`
- `lib/widgets/video_controls/widgets/vidya_course_panel.dart`
- `lib/widgets/video_controls/widgets/vidya_lecture_resources.dart`

### pubspec.yaml additions

| Package | Version | Purpose |
|---------|---------|---------|
| `permission_handler` | `^11.0.0` | Android permissions for VIDYA |
| `video_player` | `^2.9.2` | ExoPlayer for VIDYA lecture playback |

---

## Section 2 — Modified Core Logic

| File | Classification | Risk | Notes |
|------|---------------|------|-------|
| `lib/media/media_backend.dart` | Safe additive | None | `vidya` case added to enum and all switch arms |
| `lib/media/media_item.dart` | Safe additive | None | `MediaItem.vidya()` factory added as Freezed sealed variant |
| `lib/connection/connection.dart` | Safe additive | None | `VidyaAccountConnection` added as new sealed subclass |
| `lib/connection/connection_registry.dart` | Safe additive | None | `_rowToConnection()` switch extended with vidya arm |
| `lib/services/multi_server_manager.dart` | Safe additive | None | `addVidyaConnection()` / `removeVidyaConnection()` added |
| `lib/profiles/active_profile_binder.dart` | Safe additive | None | `_bindVidya()` added; existing Plex/Jellyfin paths unmodified |
| `lib/utils/media_navigation_helper.dart` | Mixed (safe intercept) | Low | Early return for `mi.backend == MediaBackend.vidya` before Plex/Jellyfin dispatch; non-Vidya paths unaffected |
| **`lib/main.dart`** | **Destructive override** | **HIGH** | See Section 3 — Priority 1 |

---

## Section 3 — Performance Anti-Patterns Found

### PRIORITY 1 — Global pointer event filter (SEVERITY: HIGH) ✅ FIXED

**File:** `lib/main.dart`
**Lines affected:** `_installZeroOffsetPointerGuard()` and `_absorbZeroOffsetPointerEvent()`

**What was changed (destructively):**

| | Original | Fork (broken) |
|--|---------|--------------|
| Platform guard | `if (_zeroOffsetPointerGuardInstalled \|\| !Platform.isIOS) return;` | `if (_zeroOffsetPointerGuardInstalled) return;` |
| Event type filter | `if (event is PointerDownEvent && event.position == Offset.zero)` | `if (event.position == Offset.zero)` |

**Effect:** The zero-offset pointer absorber was originally an iOS/tvOS-only workaround for Flutter bug #177992 (iPadOS 26.1+ fake touch events at `(0,0)` dismissing modals). By removing the `!Platform.isIOS` guard, it ran globally on every platform including Android TV and desktop. By removing the `PointerDownEvent` type check, ALL pointer event types (move, up, down) at `Offset.zero` were absorbed — not just initial presses.

**Impact on Plex/Jellyfin:** Any pointer event at `Offset.zero` on any platform was silently dropped. On Android TV D-pad this could suppress legitimate navigation input, causing intermittent focus/input sluggishness entirely unrelated to VIDYA.

**Fix applied:** Restored both guards exactly as they appeared in the original.

---

### PRIORITY 2 — Dual uncached `/api/v1/home` HTTP calls per refresh (SEVERITY: HIGH) ✅ FIXED

**File:** `lib/services/vidya_media_server_client.dart`

**Problem:** Both `fetchContinueWatching()` and `fetchGlobalHubs()` independently called `_fetchHome()`, which made a fresh uncached `GET /api/v1/home` request on every invocation. `DataAggregationService` calls both methods on every home screen refresh, resulting in two serial network requests to the VIDYA server per load cycle. This added latency that affected home screen load time even for Plex/Jellyfin users who also had a VIDYA server registered.

**Fix applied:** Added a two-layer strategy:
- **30-second TTL result cache** (`_homeCache` / `_homeCacheTime`) — subsequent calls within 30 s return the cached map instantly with no network activity.
- **In-flight deduplication** (`_pendingHomeFetch`) — if two callers race during the same uncached fetch window, they share the same `Future` rather than firing two parallel requests.

---

### PRIORITY 3 — Missing startup connection cleanup (SEVERITY: MEDIUM) ✅ FIXED

**File:** `lib/main.dart` (removed import + call)
**Restored file:** `lib/profiles/profile_connection_cleanup.dart`
**Restored methods in:** `lib/services/storage_service.dart`

**Problem:** The fork removed the import of `profile_connection_cleanup.dart` from `main.dart` and dropped the `pruneUnreferencedJellyfinConnections()` call that ran at every startup. This meant orphaned Jellyfin connections (connections with no profile referencing them) were never cleaned up. Over time and across app updates this causes stale connections to accumulate in `ConnectionRegistry`, leading to extra server binding attempts and extra fan-out targets in `DataAggregationService`.

Additionally, the fork's `StorageService` was missing the entire server-level library preference cleanup infrastructure that the cleanup file depends on:
- `clearLibraryPreferencesForServer()`
- `clearLibraryPreferencesForServerEverywhere()`
- 8 supporting private helpers (`_belongsToServer`, `_filterServerEntries*`, `_clearServerSelected*`, etc.)

**Fix applied:** Restored `profile_connection_cleanup.dart` with a `VidyaAccountConnection() => const {}` arm in `_serverIdsForConnection()` (Vidya connections carry no library preferences). Restored import and prune call in `main.dart`. Ported all missing `StorageService` methods from the original.

---

### PRIORITY 4 — `SharedPreferences.getInstance()` uncached in timer (SEVERITY: LOW-MEDIUM) ✅ FIXED

**File:** `lib/services/vidya_progress_tracker.dart`

**Problem:** `_enqueue()` and `_flushQueue()` both called `SharedPreferences.getInstance()` on every invocation. These methods are triggered from the 15-second `Timer.periodic` heartbeat callback. Under repeated network failure (VIDYA server unreachable), every 15-second tick performed a platform-channel round-trip to get a `SharedPreferences` instance, then immediately used it to append to the offline queue. Platform channel calls marshal to the platform thread and add overhead that is unnecessary when the instance can be cached.

**Fix applied:** Added `SharedPreferences? _prefs` field and `_getPrefs()` lazy caching helper. Both `_enqueue()` and `_flushQueue()` now call `_getPrefs()` which resolves the instance once and caches it for the lifetime of the tracker.

---

### ADDITIONAL — Redundant full-course fetch (SEVERITY: MEDIUM) ⚠️ NOT YET FIXED

**Files:** `lib/widgets/video_controls/widgets/vidya_lecture_resources.dart` and `lib/widgets/video_controls/widgets/vidya_course_panel.dart`

**Problem:** These two widgets independently call `fetchCourseWithContent()` when both are mounted simultaneously in `VidyaPlayerScreen`. Two redundant full HTTP requests for identical data fire on every player load and lecture switch.

**Current status:** `VidyaPlayerScreen` is unreachable dead code (no navigation path leads to it). The active player (`VidyaCoursePlayerView`) does not use either widget. Risk is dormant — no impact in production until `VidyaPlayerScreen` is revived or these widgets are reused. Tracked in backlog.

---

## Section 4 — Behavioral Red Flags (VIDYA bleeding into Plex/Jellyfin paths)

| Finding | Status |
|---------|--------|
| Pointer guard ran on all platforms, affecting all backends | ✅ Fixed |
| Startup connection cleanup removed, allowing stale Plex/Jellyfin state to accumulate | ✅ Fixed |
| Home screen latency increased when VIDYA server is online (double `_fetchHome()`) | ✅ Fixed |
| Navigation routing correctly isolates VIDYA from Plex/Jellyfin paths | Clean — no action needed |
| Playback reporting (start/progress/stop) correctly stubs out for VIDYA | Clean — no action needed |
| Library listing returns empty for VIDYA, does not pollute shared library list | Clean — no action needed |

---

## Section 5 — Structural Integrity Assessment

The VIDYA integration is **architecturally clean**. The core extension pattern (sealed class arms, interface stubs, navigation intercept) is correct and does not compromise Plex/Jellyfin code paths. All four performance regressions were localized and fixable without structural changes.

The most impactful regression (Priority 1 — pointer guard) was a two-line change in `main.dart` that had global consequences across all platforms and backends. It was almost certainly introduced to patch D-pad ghost input during VIDYA playback testing on Android TV, but applied at the wrong scope.

---

## Fixes Summary

| Priority | File | Issue | Commit |
|----------|------|-------|--------|
| 1 | `lib/main.dart` | Pointer guard globalized — restored iOS-only scope + PointerDownEvent type check | `df2c3047` |
| 2 | `lib/services/vidya_media_server_client.dart` | Dual uncached `/api/v1/home` per home refresh — added 30s TTL cache + in-flight dedup | `df2c3047` |
| 3 | `lib/profiles/profile_connection_cleanup.dart` + `lib/main.dart` + `lib/services/storage_service.dart` | Startup connection cleanup removed — restored file, prune call, and all missing StorageService helpers | `df2c3047` |
| 4 | `lib/services/vidya_progress_tracker.dart` | SharedPreferences.getInstance() uncached in timer — added lazy `_getPrefs()` cache | `df2c3047` |
