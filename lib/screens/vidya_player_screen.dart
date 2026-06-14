import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../services/vidya_connection.dart';
import '../widgets/video_controls/widgets/vidya_course_panel.dart';
import '../widgets/video_controls/widgets/vidya_lecture_resources.dart';

/// Standalone video player for VIDYA course lectures.
///
/// Uses Flutter's [video_player] plugin (ExoPlayer on Android) which renders
/// via a [Texture] widget and properly respects Flutter layout constraints —
/// unlike MPV which renders to a native surface that can bleed through.
///
/// Layout (matches the agreed ASCII mockup):
///
/// ┌──────────────────────────────────────────┬─────────────────┐
/// │  VIDEO (77%, top 75% of left column)     │ Course panel    │
/// ├──────────────────────────────────────────│ (full height)   │
/// │  controls bar                            │                 │
/// ├──────────────────────────────────────────│                 │
/// │  Resources  (bottom 25% of left column)  │                 │
/// └──────────────────────────────────────────┴─────────────────┘
class VidyaPlayerScreen extends StatefulWidget {
  final VidyaPlaybackSession session;
  final String lectureTitle;

  const VidyaPlayerScreen({
    super.key,
    required this.session,
    required this.lectureTitle,
  });

  @override
  State<VidyaPlayerScreen> createState() => _VidyaPlayerScreenState();
}

class _VidyaPlayerScreenState extends State<VidyaPlayerScreen> {
  VideoPlayerController? _controller;
  bool _initialized = false;
  String? _error;
  bool _showControls = true;
  Timer? _hideTimer;

  static const _controlsHideDuration = Duration(seconds: 4);
  static const _seekStep = Duration(seconds: 10);

  @override
  void initState() {
    super.initState();
    unawaited(_init());
  }

  Future<void> _init() async {
    final url =
        '${widget.session.baseUrl}/api/course/stream/${widget.session.lectureId}'
        '?token=${widget.session.token}';
    final ctrl = VideoPlayerController.networkUrl(Uri.parse(url));
    try {
      await ctrl.initialize();
      ctrl.addListener(_onPlayerEvent);
      await ctrl.play();
      if (!mounted) {
        await ctrl.dispose();
        return;
      }
      setState(() {
        _controller = ctrl;
        _initialized = true;
      });
      _resetHideTimer();
    } catch (e) {
      await ctrl.dispose();
      if (mounted) setState(() => _error = e.toString());
    }
  }

  void _onPlayerEvent() {
    if (mounted) setState(() {});
  }

  void _resetHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(_controlsHideDuration, () {
      if (mounted) setState(() => _showControls = false);
    });
  }

  void _showControlsTemporarily() {
    if (!_showControls) setState(() => _showControls = true);
    _resetHideTimer();
  }

  void _togglePlayPause() {
    _showControlsTemporarily();
    final ctrl = _controller;
    if (ctrl == null) return;
    if (ctrl.value.isPlaying) {
      ctrl.pause();
    } else {
      ctrl.play();
    }
  }

  void _seekBy(Duration delta) {
    _showControlsTemporarily();
    final ctrl = _controller;
    if (ctrl == null) return;
    final pos = ctrl.value.position;
    final dur = ctrl.value.duration;
    final target = pos + delta;
    final clamped = target < Duration.zero
        ? Duration.zero
        : target > dur
            ? dur
            : target;
    unawaited(ctrl.seekTo(clamped));
  }

  KeyEventResult _handleKey(FocusNode _, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    _showControlsTemporarily();
    switch (event.logicalKey) {
      case LogicalKeyboardKey.select:
      case LogicalKeyboardKey.mediaPlayPause:
      case LogicalKeyboardKey.space:
        _togglePlayPause();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowLeft:
        _seekBy(-_seekStep);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowRight:
        _seekBy(_seekStep);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.goBack:
      case LogicalKeyboardKey.escape:
        Navigator.of(context).pop();
        return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _controller?.removeListener(_onPlayerEvent);
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        autofocus: true,
        onKeyEvent: _handleKey,
        child: GestureDetector(
          onTap: _showControlsTemporarily,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Left column: video (75% height) + resources (25% height)
              Expanded(
                flex: 3,
                child: Column(
                  children: [
                    Expanded(
                      flex: 3,
                      child: _buildVideoArea(),
                    ),
                    Expanded(
                      flex: 1,
                      child: VidyaLectureResources(session: widget.session),
                    ),
                  ],
                ),
              ),
              // Right column: full-height course panel
              Expanded(
                flex: 1,
                child: VidyaCoursePanel(connection: widget.session),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildVideoArea() {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: Colors.white38, size: 48),
              const SizedBox(height: 12),
              Text(
                _error!,
                style: const TextStyle(color: Colors.white54, fontSize: 13),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              TextButton(
                onPressed: () {
                  setState(() { _error = null; _initialized = false; });
                  unawaited(_init());
                },
                child: const Text('Retry', style: TextStyle(color: Colors.white70)),
              ),
            ],
          ),
        ),
      );
    }

    if (!_initialized || _controller == null) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white54),
      );
    }

    final ctrl = _controller!;
    return Stack(
      children: [
        // Video fills the available space; AspectRatio centers with letterbox
        Center(
          child: AspectRatio(
            aspectRatio: ctrl.value.aspectRatio,
            child: VideoPlayer(ctrl),
          ),
        ),
        // Controls overlay — auto-hides
        if (_showControls) _buildControls(ctrl),
        // Buffering spinner
        if (ctrl.value.isBuffering)
          const Center(
            child: CircularProgressIndicator(color: Colors.white54, strokeWidth: 2),
          ),
      ],
    );
  }

  Widget _buildControls(VideoPlayerController ctrl) {
    final position = ctrl.value.position;
    final duration = ctrl.value.duration;
    final isPlaying = ctrl.value.isPlaying;
    final progress = duration.inMilliseconds > 0
        ? (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color(0xBB000000),
            Colors.transparent,
            Colors.transparent,
            Color(0xCC000000),
          ],
          stops: [0.0, 0.2, 0.65, 1.0],
        ),
      ),
      child: Column(
        children: [
          // Top bar: back + title
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 16, 0),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
                  onPressed: () => Navigator.of(context).pop(),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    widget.lectureTitle,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      shadows: [Shadow(blurRadius: 4)],
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          const Spacer(),
          // Bottom controls
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
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
                    // Seek back
                    IconButton(
                      icon: const Icon(Icons.replay_10_rounded, color: Colors.white),
                      iconSize: 28,
                      onPressed: () => _seekBy(-_seekStep),
                    ),
                    // Play / pause — large for TV remote
                    IconButton(
                      icon: Icon(
                        isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                        color: Colors.white,
                      ),
                      iconSize: 42,
                      onPressed: _togglePlayPause,
                    ),
                    // Seek forward
                    IconButton(
                      icon: const Icon(Icons.forward_10_rounded, color: Colors.white),
                      iconSize: 28,
                      onPressed: () => _seekBy(_seekStep),
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

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }
}
