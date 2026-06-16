# CLAUDE.md — Plezy (with VIDYA support)

> Last updated: 2026-06-16 — Feature Vertical 4 complete (VIDYA on home screen)

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
- Call `detach()` in `dispose()` to cancel timer and remove listener
- Call `attach()` again when lecture changes; old listener/timer cleaned up automatically

---

## Key files

| File | Purpose |
|------|---------|
| `lib/screens/vidya_course_player_view.dart` | **Current** VIDYA player — Udemy-style split layout, sidebar, auto-next |
| `lib/screens/vidya_player_screen.dart` | Legacy VIDYA player — kept for reference, no longer routed to |
| `lib/screens/vidya_course_browser_screen.dart` | Course browser → pushes `VidyaCoursePlayerView` |
| `lib/widgets/video_controls/widgets/vidya_course_panel.dart` | Original in-player panel (Course Content + User Uploads tabs) — not used by new player |
| `lib/widgets/video_controls/widgets/vidya_lecture_resources.dart` | Original resources strip — not used by new player |
| `lib/services/vidya_api_client.dart` | HTTP client: `VidyaApiClient` (session-scoped) + `VidyaBrowseClient` (browse + outline) |
| `lib/services/vidya_connection.dart` | `VidyaPlaybackSession` model |
| `lib/services/vidya_progress_tracker.dart` | Heartbeat tracker + offline queue |
| `lib/connection/connection.dart` | `VidyaAccountConnection` sealed class |
| `lib/screens/settings/add_vidya_screen.dart` | Add-connection form → `POST /api/auth/token` |
| `lib/services/vidya_media_server_client.dart` | `MediaServerClient` stub for VIDYA — wires into `DataAggregationService` for home screen |
| `lib/services/vidya_token_manager.dart` | JWT auto-refresh wrapper; `fromConnection(conn, registry)` for browse/home; `fromSession(session)` for player |
| `lib/services/multi_server_manager.dart` | `addVidyaConnection(conn, registry)` / `removeVidyaConnection(conn)` |
| `lib/profiles/active_profile_binder.dart` | `_bindVidya(conn)` called for `VidyaAccountConnection` on profile activation |
| `lib/utils/media_navigation_helper.dart` | VIDYA intercept before kind-switch: episode → player with resume, show → course browser |

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

## CI / build

- GitHub Actions builds APK on every push to `main`
- `video_player: ^2.9.2` is in `pubspec.yaml` (used for VIDYA)
- `android:usesCleartextTraffic="true"` is set in AndroidManifest — HTTP VIDYA servers work

## Platform target

- Primary: **Android TV / Google TV** (D-pad / controller input, no touch)
- VIDYA server is self-hosted, accessed over local network (HTTP)
