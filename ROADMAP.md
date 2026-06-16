# Plezy — Roadmap

> Last updated: 2026-06-16 — Feature Verticals 2 & 3 complete

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

## Future / Backlog

- Token refresh flow in `VidyaApiClient` — refresh JWT automatically when 401 received during playback
- D-pad seek-bar scrubbing — hold Left/Right to skip in larger increments
- Subtitle track selection for VIDYA lectures (SRT → WebVTT served by server)
- Resume-from-last-position on launch — use `watch_time` from outline to seek on `_initVideo`
- Connection health check / reconnect screen on network loss mid-playback
