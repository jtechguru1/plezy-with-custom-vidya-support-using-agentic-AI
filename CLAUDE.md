# CLAUDE.md — Plezy (with VIDYA support)

## What this project is

**Plezy** is a Flutter app for Android TV / Google TV that streams media from Plex and Jellyfin servers. It uses the **media_kit** package (MPV) for Plex/Jellyfin video playback.

**VIDYA** is a separate self-hosted course platform (like Udemy) that was added as a custom feature. VIDYA has its own video player, separate from the MPV player used for Plex/Jellyfin.

## Critical architecture decision: two separate video players

- **Plex / Jellyfin** → `VideoPlayerScreen` → MPV via `media_kit` / `Video` widget
- **VIDYA** → `VidyaPlayerScreen` → ExoPlayer via the `video_player` Flutter plugin

**Why separate?** MPV renders to a native Android `SurfaceView` that bypasses Flutter layout constraints — `Expanded`/`AnimatedPadding` constrains the Flutter widget box but the actual video surface bleeds through full-screen. The `video_player` plugin uses a `Texture` widget that genuinely respects Flutter layout bounds, which is required for the VIDYA side-by-side layout.

**Never route VIDYA lectures through `VideoPlayerScreen` or MPV.** They must go through `VidyaPlayerScreen`.

## VIDYA screen layout

```
┌─────────────────────────────────────┬──────────────┐
│  VIDEO (Expanded flex:3)            │ Course panel │
│  video_player / ExoPlayer           │ (flex:1)     │
│  AspectRatio + letterbox            │              │
│  Controls overlay (auto-hides 4s)   │ Course tab   │
├─────────────────────────────────────│ User Uploads │
│  Resources strip (Expanded flex:1)  │ tab          │
│  Shows cleanedName.type for files   │              │
└─────────────────────────────────────┴──────────────┘
Left column = Expanded(flex:3), right panel = Expanded(flex:1)
Left column splits 75/25 vertically (video top, resources bottom)
```

## D-pad / controller navigation (VidyaPlayerScreen)

- **Video area focus** (default): left/right = ±10s seek, OK/select = play/pause, down = enter panel, back = exit screen
- **Panel focus**: up/down = navigate lecture list, left or back = return to video (does NOT exit screen)
- Focus color for highlighted panel items: `#A435F0` at 55% opacity
- Currently-playing lecture: `#A435F0` at 25% opacity background tint

## Key files

| File | Purpose |
|------|---------|
| `lib/screens/vidya_player_screen.dart` | Standalone VIDYA player (video_player, layout, D-pad, lecture switching) |
| `lib/screens/vidya_course_browser_screen.dart` | Course browser → navigates to VidyaPlayerScreen |
| `lib/widgets/video_controls/widgets/vidya_course_panel.dart` | Right-column panel (Course Content + User Uploads tabs) |
| `lib/widgets/video_controls/widgets/vidya_lecture_resources.dart` | Bottom-left Resources strip (read-only, text-only) |
| `lib/services/vidya_api_client.dart` | HTTP client for VIDYA API |
| `lib/services/vidya_connection.dart` | `VidyaPlaybackSession` and `VidyaAccountConnection` models |

## VIDYA API notes

- `GET /api/course/:courseId` — uses `getCourseData()`, **omits** `content` (resources) from lecture objects
- `POST /api/course/player` with body `{"CourseId": "..."}` — **includes** `content` per lecture; use `fetchCourseWithContent()` for anything that needs resources
- Stream URL: `${baseUrl}/api/course/stream/${lectureId}?token=${token}` — token in query string, no auth headers needed (`verifyQueryToken` middleware)
- `android:usesCleartextTraffic="true"` is already set in AndroidManifest — HTTP VIDYA servers work fine

## Lecture switching

`VidyaPlayerScreen` tracks `_currentLectureId` and `_currentLectureTitle` as mutable state. `_switchLecture(lectureId, lectureName)` disposes the old `VideoPlayerController`, updates state, and calls `_init()` with the new stream URL. The panel receives `onLectureSelected: _switchLecture` as a callback.

## Panel rules

- **Course Content tab**: lists all sections and lectures; tapping a lecture calls `onLectureSelected`
- **User Uploads tab**: lists uploads, no upload button (read-only list only)
- **No Resources tab in the panel** — resources are shown in the bottom-left strip instead

## CI / build

- GitHub Actions builds the APK on every push to `main`
- `video_player: ^2.9.2` is in `pubspec.yaml`

## Platform target

- Primary: **Android TV / Google TV** (controller/D-pad input, no touch)
- User runs the app on a **TV with a Google TV remote**
- VIDYA server is self-hosted, accessed over local network (HTTP)
