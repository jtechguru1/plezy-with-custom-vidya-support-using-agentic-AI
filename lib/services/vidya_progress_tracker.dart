import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

/// Attaches to a [VideoPlayerController] and drives progress sync to the Vidya
/// server (`POST /api/v1/progress/sync`) while a Vidya lecture is playing.
///
/// Isolation guarantee: this class is instantiated only from Vidya-specific
/// screens. It has zero imports from the Plex or Jellyfin layers.
///
/// Heartbeat cadence: every 15 s while the video is playing.
/// Immediate sync: on pause and on completion.
/// Offline queue: failures are stored in SharedPreferences under
/// [_queueKey] and flushed automatically after the next successful sync.
class VidyaPlaybackTracker {
  final String baseUrl;
  final String accessToken;
  final String courseId;

  VidyaPlaybackTracker({
    required this.baseUrl,
    required this.accessToken,
    required this.courseId,
  });

  static const _queueKey = 'vidya_offline_sync_queue';
  static const _heartbeatInterval = Duration(seconds: 15);

  VideoPlayerController? _controller;
  String _lectureId = '';

  Timer? _heartbeatTimer;
  bool _wasPlaying = false;
  bool _completionFired = false;

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Attaches to [ctrl] and begins tracking for [lectureId].
  /// Safe to call again when the lecture changes: the previous listener and
  /// timer are cleaned up before the new ones are registered.
  void attach(VideoPlayerController ctrl, {required String lectureId}) {
    _detachController();
    _controller = ctrl;
    _lectureId = lectureId;
    _wasPlaying = false;
    _completionFired = false;
    ctrl.addListener(_onValue);
    _startHeartbeat();
  }

  /// Removes all listeners and cancels the heartbeat. Call from [dispose].
  void detach() {
    _detachController();
  }

  /// Manually flushes the offline queue. Can be called externally when
  /// connectivity is restored (e.g., from a network-change listener).
  Future<void> flushQueue() => _flushQueue();

  // ── Internal ───────────────────────────────────────────────────────────────

  void _detachController() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _controller?.removeListener(_onValue);
    _controller = null;
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(_heartbeatInterval, (_) {
      final ctrl = _controller;
      if (ctrl != null && ctrl.value.isPlaying) {
        unawaited(_sync(false));
      }
    });
  }

  void _onValue() {
    final ctrl = _controller;
    if (ctrl == null) return;
    final v = ctrl.value;

    // Pause event: was playing, now stopped (not at the very end).
    if (_wasPlaying && !v.isPlaying && !_isAtEnd(v)) {
      unawaited(_sync(false));
    }
    _wasPlaying = v.isPlaying;

    // Completion event: position reached end.
    if (_isAtEnd(v) && !_completionFired) {
      _completionFired = true;
      unawaited(_sync(true));
    }
  }

  bool _isAtEnd(VideoPlayerValue v) {
    return !v.isPlaying &&
        v.duration > Duration.zero &&
        v.position >= v.duration - const Duration(milliseconds: 500);
  }

  Future<void> _sync(bool isCompleted) async {
    final ctrl = _controller;
    if (ctrl == null) return;
    final timeSeconds = ctrl.value.position.inMilliseconds / 1000.0;
    final lid = _lectureId;
    final cid = courseId;

    try {
      await _postSync(
        courseId: cid,
        lessonId: lid,
        timeSeconds: timeSeconds,
        isCompleted: isCompleted,
      );
      unawaited(_flushQueue());
    } catch (_) {
      await _enqueue(
        courseId: cid,
        lessonId: lid,
        timeSeconds: timeSeconds,
        isCompleted: isCompleted,
      );
    }
  }

  Future<void> _postSync({
    required String courseId,
    required String lessonId,
    required double timeSeconds,
    required bool isCompleted,
  }) async {
    final uri = Uri.parse('$baseUrl/api/v1/progress/sync');
    final response = await http.post(
      uri,
      headers: {
        'Authorization': 'Bearer $accessToken',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'course_id': courseId,
        'lesson_id': lessonId,
        'time_seconds': timeSeconds,
        'is_completed': isCompleted,
      }),
    );
    if (response.statusCode != 200) {
      throw Exception('${response.statusCode}');
    }
  }

  Future<void> _enqueue({
    required String courseId,
    required String lessonId,
    required double timeSeconds,
    required bool isCompleted,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_queueKey) ?? '[]';
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      list.add({
        'course_id': courseId,
        'lesson_id': lessonId,
        'time_seconds': timeSeconds,
        'is_completed': isCompleted,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });
      await prefs.setString(_queueKey, jsonEncode(list));
    } catch (_) {
      // Swallow: if we can't queue it either, the progress is lost but the
      // app must not crash.
    }
  }

  Future<void> _flushQueue() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_queueKey) ?? '[]';
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      if (list.isEmpty) return;

      final failed = <Map<String, dynamic>>[];
      for (final item in list) {
        try {
          await _postSync(
            courseId: item['course_id'] as String,
            lessonId: item['lesson_id'] as String,
            timeSeconds: (item['time_seconds'] as num).toDouble(),
            isCompleted: item['is_completed'] as bool? ?? false,
          );
        } catch (_) {
          failed.add(item);
        }
      }
      await prefs.setString(_queueKey, jsonEncode(failed));
    } catch (_) {
      // Swallow: flush is best-effort.
    }
  }
}
