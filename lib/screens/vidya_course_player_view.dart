import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:video_player/video_player.dart';

import '../services/vidya_api_client.dart';
import '../services/vidya_connection.dart';
import '../services/vidya_progress_tracker.dart';

// ── Domain model ──────────────────────────────────────────────────────────────

class _Attachment {
  final String name;
  final String type;

  const _Attachment({required this.name, required this.type});
}

class _Lesson {
  final String id;
  final String title;
  final String sectionId;
  final String sectionTitle;
  final String type;
  final double duration;
  bool isCompleted;
  final List<_Attachment> attachments;

  _Lesson({
    required this.id,
    required this.title,
    required this.sectionId,
    required this.sectionTitle,
    required this.type,
    required this.duration,
    required this.isCompleted,
    required this.attachments,
  });
}

// ── Screen ────────────────────────────────────────────────────────────────────

/// Standalone Google TV player for VIDYA course lectures.
///
/// Isolation guarantee: this screen is pushed only from Vidya-specific browser
/// screens. It has zero imports from the Plex or Jellyfin layers, and it does
/// not touch or extend any shared player base class.
///
/// Layout (D-pad navigable):
///
/// ┌────────────────────────────────────────────────┬───────────────────┐
/// │  VIDEO CANVAS (80% width)                      │  Course Sidebar   │
/// │                                                │  (20%, toggleable)│
/// │  [Course › Section › Lesson]  (top overlay)   │  § Section 1      │
/// │                                                │    ✓ Lesson 1.1   │
/// │  Controls overlay (show/hide):                 │    ▶ Lesson 1.2   │
/// │    [←10]  [▶/⏸]  [10→]   ══════  0:00/0:00   │    ○ Lesson 1.3   │
/// └────────────────────────────────────────────────┴───────────────────┘
///
/// D-pad rules:
///   Right  → open sidebar + shift focus there
///   Left   → close sidebar / return to video
///   Down   → show controls overlay
///   Select → play / pause
///   ←/→    → seek ±10 s (when focus is in video area)
class VidyaCoursePlayerView extends StatefulWidget {
  final VidyaPlaybackSession session;
  final String initialLectureTitle;

  const VidyaCoursePlayerView({
    super.key,
    required this.session,
    required this.initialLectureTitle,
  });

  @override
  State<VidyaCoursePlayerView> createState() => _VidyaCoursePlayerViewState();
}

class _VidyaCoursePlayerViewState extends State<VidyaCoursePlayerView> {
  // ── Outline ──────────────────────────────────────────────────────────────
  String _courseTitle = '';
  List<_Lesson> _lessons = [];
  bool _outlineLoading = true;

  // ── Playback ─────────────────────────────────────────────────────────────
  VideoPlayerController? _controller;
  bool _videoInitialized = false;
  String? _videoError;

  String _currentLessonId = '';
  bool _completionFired = false;

  // ── Tracker ──────────────────────────────────────────────────────────────
  late final VidyaPlaybackTracker _tracker;

  // ── UI state ─────────────────────────────────────────────────────────────
  bool _showControls = true;
  bool _sidebarVisible = true;
  Timer? _hideTimer;
  Timer? _sidebarHideTimer;

  // ── Focus ────────────────────────────────────────────────────────────────
  final FocusNode _videoFocus = FocusNode(debugLabel: 'VidyaPlayer:Video');
  final FocusScopeNode _sidebarScope = FocusScopeNode(debugLabel: 'VidyaPlayer:Sidebar');

  static const _seekStep = Duration(seconds: 10);
  static const _controlsHideDuration = Duration(seconds: 4);
  static const _sidebarHideDuration = Duration(seconds: 12);

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _currentLessonId = widget.session.lectureId;
    _tracker = VidyaPlaybackTracker(
      baseUrl: widget.session.baseUrl,
      accessToken: widget.session.token,
      courseId: widget.session.courseId,
    );
    unawaited(_loadOutline());
    unawaited(_initVideo(_currentLessonId));
    _startSidebarHideTimer();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _sidebarHideTimer?.cancel();
    // Final sync before tearing down so the server always gets the last position.
    unawaited(_tracker.syncNow(isCompleted: _completionFired));
    _tracker.detach();
    _controller?.removeListener(_onControllerValue);
    _controller?.dispose();
    _videoFocus.dispose();
    _sidebarScope.dispose();
    super.dispose();
  }

  // ── Outline ───────────────────────────────────────────────────────────────

  Future<void> _loadOutline() async {
    final client = VidyaBrowseClient(
      baseUrl: widget.session.baseUrl,
      accessToken: widget.session.token,
    );
    try {
      final outline = await client.fetchOutline(widget.session.courseId);
      if (!mounted) return;
      setState(() {
        _courseTitle = outline['title'] as String? ?? '';
        _lessons = _flattenLessons(outline);
        _outlineLoading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _outlineLoading = false);
    }
  }

  List<_Lesson> _flattenLessons(Map<String, dynamic> outline) {
    final result = <_Lesson>[];
    final sections = (outline['sections'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    for (final section in sections) {
      final sectionId = section['id'] as String? ?? '';
      final sectionTitle = section['title'] as String? ?? '';
      final lessons = (section['lessons'] as List?)?.cast<Map<String, dynamic>>() ?? [];
      for (final lesson in lessons) {
        final rawAttachments =
            (lesson['attachments'] as List?)?.cast<Map<String, dynamic>>() ?? [];
        result.add(_Lesson(
          id: lesson['id'] as String? ?? '',
          title: lesson['title'] as String? ?? '',
          sectionId: sectionId,
          sectionTitle: sectionTitle,
          type: lesson['type'] as String? ?? 'video',
          duration: (lesson['duration'] as num?)?.toDouble() ?? 0.0,
          isCompleted: lesson['is_completed'] == true,
          attachments: rawAttachments
              .map((a) => _Attachment(
                    name: a['name'] as String? ?? 'File',
                    type: a['type'] as String? ?? '',
                  ))
              .toList(),
        ));
      }
    }
    return result;
  }

  // ── Video ─────────────────────────────────────────────────────────────────

  Future<void> _initVideo(String lectureId) async {
    final url =
        '${widget.session.baseUrl}/api/course/stream/$lectureId'
        '?token=${widget.session.token}';
    final ctrl = VideoPlayerController.networkUrl(Uri.parse(url));
    try {
      await ctrl.initialize();
      ctrl.addListener(_onControllerValue);
      await ctrl.play();
      if (!mounted) {
        await ctrl.dispose();
        return;
      }
      _tracker.attach(ctrl, lectureId: lectureId);
      setState(() {
        _controller = ctrl;
        _videoInitialized = true;
        _videoError = null;
        _completionFired = false;
      });
      _resetHideTimer();
    } catch (e) {
      await ctrl.dispose();
      if (mounted) setState(() => _videoError = e.toString());
    }
  }

  void _onControllerValue() {
    if (!mounted) return;

    final v = _controller?.value;
    if (v == null) return;

    // Detect completion for auto-next.
    final isEnded = !v.isPlaying &&
        v.duration > Duration.zero &&
        v.position >= v.duration - const Duration(milliseconds: 500);
    if (isEnded && !_completionFired) {
      _completionFired = true;
      unawaited(_advanceToNextLesson());
    }

    setState(() {});
  }

  Future<void> _switchLesson(String lessonId, String lessonTitle) async {
    if (lessonId == _currentLessonId) return;
    _hideTimer?.cancel();
    // Sync current position before switching — captures values synchronously
    // so it's safe to call before detach.
    unawaited(_tracker.syncNow(isCompleted: _completionFired));
    _tracker.detach();

    final old = _controller;
    old?.removeListener(_onControllerValue);
    setState(() {
      _controller = null;
      _videoInitialized = false;
      _videoError = null;
      _currentLessonId = lessonId;
      _completionFired = false;
      _showControls = true;
    });
    await old?.dispose();
    unawaited(_initVideo(lessonId));
    _videoFocus.requestFocus();
  }

  Future<void> _advanceToNextLesson() async {
    // Mark current complete in local outline.
    _markLocalComplete(_currentLessonId);

    final idx = _lessons.indexWhere((l) => l.id == _currentLessonId);
    for (var i = idx + 1; i < _lessons.length; i++) {
      final next = _lessons[i];
      if (next.type.toLowerCase() == 'video') {
        await _switchLesson(next.id, next.title);
        return;
      }
    }
    // No more video lessons — stay on current (end of course).
  }

  void _markLocalComplete(String lessonId) {
    final idx = _lessons.indexWhere((l) => l.id == lessonId);
    if (idx >= 0 && !_lessons[idx].isCompleted) {
      setState(() => _lessons[idx].isCompleted = true);
    }
  }

  // ── Controls ──────────────────────────────────────────────────────────────

  void _resetHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(_controlsHideDuration, () {
      if (mounted) setState(() => _showControls = false);
    });
  }

  void _revealControls() {
    if (!_showControls) setState(() => _showControls = true);
    _resetHideTimer();
  }

  void _startSidebarHideTimer() {
    _sidebarHideTimer?.cancel();
    _sidebarHideTimer = Timer(_sidebarHideDuration, () {
      if (mounted && _sidebarVisible) {
        setState(() => _sidebarVisible = false);
        _videoFocus.requestFocus();
      }
    });
  }

  void _cancelSidebarHideTimer() {
    _sidebarHideTimer?.cancel();
    _sidebarHideTimer = null;
  }

  void _togglePlayPause() {
    _revealControls();
    final ctrl = _controller;
    if (ctrl == null) return;
    ctrl.value.isPlaying ? ctrl.pause() : ctrl.play();
  }

  void _seek(Duration delta) {
    _revealControls();
    final ctrl = _controller;
    if (ctrl == null) return;
    final target = ctrl.value.position + delta;
    final dur = ctrl.value.duration;
    final clamped = target < Duration.zero
        ? Duration.zero
        : target > dur
            ? dur
            : target;
    unawaited(ctrl.seekTo(clamped));
  }

  // ── Focus / D-pad ─────────────────────────────────────────────────────────

  KeyEventResult _handleVideoKey(FocusNode _, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    _revealControls();

    switch (event.logicalKey) {
      case LogicalKeyboardKey.select:
      case LogicalKeyboardKey.mediaPlayPause:
      case LogicalKeyboardKey.space:
        _togglePlayPause();
        return KeyEventResult.handled;

      case LogicalKeyboardKey.arrowLeft:
        _seek(-_seekStep);
        return KeyEventResult.handled;

      case LogicalKeyboardKey.arrowRight:
        _seek(_seekStep);
        return KeyEventResult.handled;

      case LogicalKeyboardKey.arrowDown:
        setState(() => _showControls = true);
        _resetHideTimer();
        return KeyEventResult.handled;

      case LogicalKeyboardKey.arrowUp:
        // Up: show sidebar if hidden, then move focus into it.
        if (!_sidebarVisible) setState(() => _sidebarVisible = true);
        _cancelSidebarHideTimer();
        _sidebarScope.requestFocus();
        return KeyEventResult.handled;

      case LogicalKeyboardKey.goBack:
      case LogicalKeyboardKey.escape:
        unawaited(_tracker.syncNow(isCompleted: _completionFired));
        Navigator.of(context).pop();
        return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _handleSidebarKey(FocusNode _, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
        event.logicalKey == LogicalKeyboardKey.goBack ||
        event.logicalKey == LogicalKeyboardKey.escape) {
      _videoFocus.requestFocus();
      _startSidebarHideTimer();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  _Lesson? get _currentLesson =>
      _lessons.where((l) => l.id == _currentLessonId).firstOrNull;

  String get _breadcrumb {
    final lesson = _currentLesson;
    if (lesson == null) return _courseTitle;
    final parts = <String>[
      if (_courseTitle.isNotEmpty) _courseTitle,
      if (lesson.sectionTitle.isNotEmpty) lesson.sectionTitle,
      lesson.title,
    ];
    return parts.join(' › ');
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: _revealControls,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Left / Center: video + controls (75% when sidebar open, 100% when closed)
            Expanded(
              flex: _sidebarVisible ? 3 : 1,
              child: Focus(
                focusNode: _videoFocus,
                autofocus: true,
                onKeyEvent: _handleVideoKey,
                child: _buildVideoColumn(),
              ),
            ),
            // Right sidebar (20%): visible only when _sidebarVisible
            if (_sidebarVisible)
              Expanded(
                flex: 1,
                child: Focus(
                  onKeyEvent: _handleSidebarKey,
                  child: FocusScope(
                    node: _sidebarScope,
                    child: _buildSidebar(),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildVideoColumn() {
    return Stack(
      children: [
        _buildVideoArea(),
        if (_showControls) _buildControlsOverlay(),
        if (_controller?.value.isBuffering == true)
          const Center(
            child: CircularProgressIndicator(color: Colors.white54, strokeWidth: 2),
          ),
      ],
    );
  }

  Widget _buildVideoArea() {
    if (_videoError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: Colors.white38, size: 48),
              const SizedBox(height: 12),
              Text(_videoError!,
                  style: const TextStyle(color: Colors.white54, fontSize: 13),
                  textAlign: TextAlign.center),
              const SizedBox(height: 16),
              TextButton(
                onPressed: () {
                  setState(() {
                    _videoError = null;
                    _videoInitialized = false;
                  });
                  unawaited(_initVideo(_currentLessonId));
                },
                child: const Text('Retry', style: TextStyle(color: Colors.white70)),
              ),
            ],
          ),
        ),
      );
    }

    if (!_videoInitialized || _controller == null) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white54),
      );
    }

    return Center(
      child: AspectRatio(
        aspectRatio: _controller!.value.aspectRatio,
        child: VideoPlayer(_controller!),
      ),
    );
  }

  Widget _buildControlsOverlay() {
    final ctrl = _controller;
    final position = ctrl?.value.position ?? Duration.zero;
    final duration = ctrl?.value.duration ?? Duration.zero;
    final isPlaying = ctrl?.value.isPlaying ?? false;
    final progress = duration.inMilliseconds > 0
        ? (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color(0xCC000000),
            Colors.transparent,
            Colors.transparent,
            Color(0xDD000000),
          ],
          stops: [0.0, 0.18, 0.65, 1.0],
        ),
      ),
      child: Column(
        children: [
          // ── Breadcrumb ─────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
                  onPressed: () => Navigator.of(context).pop(),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    _breadcrumb,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      shadows: [Shadow(blurRadius: 4)],
                    ),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ),
                // Sidebar toggle hint
                if (!_sidebarVisible)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Icon(
                      Symbols.menu_open_rounded,
                      color: Colors.white54,
                      size: 20,
                    ),
                  ),
              ],
            ),
          ),

          const Spacer(),

          // ── Transport controls + progress bar ──────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Progress bar
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: progress,
                    backgroundColor: Colors.white24,
                    valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
                    minHeight: 3,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Text(
                      _fmt(position),
                      style: const TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.replay_10_rounded, color: Colors.white),
                      iconSize: 28,
                      onPressed: () => _seek(-_seekStep),
                    ),
                    IconButton(
                      icon: Icon(
                        isPlaying
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        color: Colors.white,
                      ),
                      iconSize: 44,
                      onPressed: _togglePlayPause,
                    ),
                    IconButton(
                      icon: const Icon(Icons.forward_10_rounded, color: Colors.white),
                      iconSize: 28,
                      onPressed: () => _seek(_seekStep),
                    ),
                    const Spacer(),
                    Text(
                      _fmt(duration),
                      style: const TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Sidebar ───────────────────────────────────────────────────────────────

  Widget _buildSidebar() {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xE6000000),
        border: Border(left: BorderSide(color: Colors.white12)),
      ),
      child: Column(
        children: [
          // Header
          Container(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: Colors.white12)),
            ),
            child: Row(
              children: [
                const Icon(Symbols.menu_book_rounded, color: Colors.white54, size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Course Content',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.3,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),

          // Lesson list
          Expanded(
            child: _outlineLoading
                ? const Center(
                    child: CircularProgressIndicator(
                      color: Colors.white38,
                      strokeWidth: 2,
                    ),
                  )
                : _lessons.isEmpty
                    ? const Center(
                        child: Text(
                          'No lessons found',
                          style: TextStyle(color: Colors.white38, fontSize: 12),
                        ),
                      )
                    : _buildLessonList(),
          ),
        ],
      ),
    );
  }

  Widget _buildLessonList() {
    // Group by section for display.
    final sectionOrder = <String>[];
    final bySection = <String, List<_Lesson>>{};
    for (final lesson in _lessons) {
      if (!bySection.containsKey(lesson.sectionId)) {
        sectionOrder.add(lesson.sectionId);
        bySection[lesson.sectionId] = [];
      }
      bySection[lesson.sectionId]!.add(lesson);
    }

    final items = <Widget>[];
    for (final sectionId in sectionOrder) {
      final sectionLessons = bySection[sectionId]!;
      // Section header — non-focusable
      items.add(
        ExcludeFocus(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
            child: Text(
              sectionLessons.first.sectionTitle,
              style: const TextStyle(
                color: Colors.white54,
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      );

      for (final lesson in sectionLessons) {
        items.add(_buildLessonTile(lesson));
      }
    }

    return ListView(
      padding: const EdgeInsets.only(bottom: 12),
      children: items,
    );
  }

  Widget _buildLessonTile(_Lesson lesson) {
    final isCurrent = lesson.id == _currentLessonId;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Lesson row (focusable)
        Focus(
          onKeyEvent: (node, event) {
            if (event is KeyUpEvent) return KeyEventResult.ignored;
            if (event.logicalKey == LogicalKeyboardKey.select ||
                event.logicalKey == LogicalKeyboardKey.enter) {
              if (!isCurrent) {
                unawaited(_switchLesson(lesson.id, lesson.title));
                _videoFocus.requestFocus();
                _startSidebarHideTimer();
              }
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: Builder(
            builder: (context) {
              final hasFocus = Focus.of(context).hasFocus;
              return GestureDetector(
                onTap: isCurrent
                    ? null
                    : () {
                        unawaited(_switchLesson(lesson.id, lesson.title));
                        _videoFocus.requestFocus();
                        _startSidebarHideTimer();
                      },
                child: Container(
                  color: isCurrent
                      ? const Color(0xFFA435F0).withValues(alpha: 0.28)
                      : hasFocus
                          ? Colors.white.withValues(alpha: 0.08)
                          : Colors.transparent,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: Row(
                    children: [
                      // Status icon
                      Icon(
                        isCurrent
                            ? Symbols.play_circle_rounded
                            : lesson.isCompleted
                                ? Symbols.check_circle_rounded
                                : Symbols.radio_button_unchecked_rounded,
                        color: isCurrent
                            ? const Color(0xFFA435F0)
                            : lesson.isCompleted
                                ? Colors.greenAccent.shade400
                                : Colors.white38,
                        size: 16,
                        fill: lesson.isCompleted ? 1 : 0,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          lesson.title,
                          style: TextStyle(
                            color: isCurrent ? Colors.white : Colors.white70,
                            fontSize: 11,
                            fontWeight:
                                isCurrent ? FontWeight.w600 : FontWeight.normal,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (lesson.duration > 0)
                        Padding(
                          padding: const EdgeInsets.only(left: 4),
                          child: Text(
                            _fmtSeconds(lesson.duration),
                            style: const TextStyle(
                                color: Colors.white38, fontSize: 10),
                          ),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),

        // Attachments for the current lesson — non-interactive, D-pad skipped.
        if (isCurrent && lesson.attachments.isNotEmpty)
          ExcludeFocus(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(36, 4, 12, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Attachments',
                    style: const TextStyle(
                      color: Colors.white38,
                      fontSize: 9,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.4,
                    ),
                  ),
                  const SizedBox(height: 2),
                  ...lesson.attachments.map(
                    (a) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 1),
                      child: Row(
                        children: [
                          Icon(
                            _attachmentIcon(a.type),
                            color: Colors.white24,
                            size: 11,
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              a.type.isNotEmpty ? '${a.name}.${a.type}' : a.name,
                              style: const TextStyle(
                                  color: Colors.white38, fontSize: 10),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  // ── Utilities ─────────────────────────────────────────────────────────────

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  String _fmtSeconds(double seconds) {
    final total = seconds.round();
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    if (h > 0) return '${h}h ${m.toString().padLeft(2, '0')}m';
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  IconData _attachmentIcon(String type) {
    switch (type.toLowerCase()) {
      case 'pdf':
        return Symbols.picture_as_pdf_rounded;
      case 'mp3':
      case 'wav':
        return Symbols.audio_file_rounded;
      case 'jpg':
      case 'jpeg':
      case 'png':
        return Symbols.image_rounded;
      case 'zip':
      case 'rar':
        return Symbols.folder_zip_rounded;
      default:
        return Symbols.description_rounded;
    }
  }
}
