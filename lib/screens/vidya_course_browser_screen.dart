import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../connection/connection.dart';
import '../focus/focusable_button.dart';
import '../media/media_backend.dart';
import '../media/media_item.dart';
import '../media/media_kind.dart';
import '../providers/vidya_session_provider.dart';
import '../services/playback_context.dart';
import '../services/playback_initialization_types.dart';
import '../services/vidya_api_client.dart';
import '../services/vidya_connection.dart';
import '../widgets/focused_scroll_scaffold.dart';
import '../utils/video_player_navigation.dart' show kVideoPlayerRouteName;
import 'video_player_screen.dart';

/// Two-level VIDYA course browser.
///
/// Shows all courses from the connected VIDYA server. Tapping a course drills
/// into its sections and lectures. Tapping a lecture sets the
/// [VidyaSessionProvider] session and launches the video stream.
class VidyaCourseBrowserScreen extends StatefulWidget {
  final VidyaAccountConnection connection;

  const VidyaCourseBrowserScreen({super.key, required this.connection});

  @override
  State<VidyaCourseBrowserScreen> createState() => _VidyaCourseBrowserScreenState();
}

class _VidyaCourseBrowserScreenState extends State<VidyaCourseBrowserScreen> {
  late final VidyaBrowseClient _client;

  List<Map<String, dynamic>>? _courses;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _client = VidyaBrowseClient(
      baseUrl: widget.connection.baseUrl,
      accessToken: widget.connection.accessToken,
    );
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final courses = await _client.fetchCourses();
      if (mounted) setState(() => _courses = courses);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _openCourse(Map<String, dynamic> course) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => VidyaCourseDetailScreen(
          client: _client,
          course: course,
          connection: widget.connection,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FocusedScrollScaffold(
      title: Text('${widget.connection.serverName} — Courses'),
      slivers: [
        if (_loading)
          const SliverFillRemaining(child: Center(child: CircularProgressIndicator()))
        else if (_error != null)
          SliverFillRemaining(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Symbols.error_outline_rounded, size: 48, color: theme.colorScheme.error),
                    const SizedBox(height: 12),
                    Text(_error!, textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                    FocusableButton(
                      onPressed: _load,
                      child: FilledButton(onPressed: _load, child: const Text('Retry')),
                    ),
                  ],
                ),
              ),
            ),
          )
        else if (_courses == null || _courses!.isEmpty)
          const SliverFillRemaining(child: Center(child: Text('No courses found.')))
        else
          SliverPadding(
            padding: const EdgeInsets.all(16),
            sliver: SliverGrid.builder(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 260,
                childAspectRatio: 16 / 10,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
              ),
              itemCount: _courses!.length,
              itemBuilder: (context, i) => _CourseCard(
                course: _courses![i],
                baseUrl: widget.connection.baseUrl,
                onTap: () => _openCourse(_courses![i]),
              ),
            ),
          ),
      ],
    );
  }
}

class _CourseCard extends StatelessWidget {
  final Map<String, dynamic> course;
  final String baseUrl;
  final VoidCallback onTap;

  const _CourseCard({required this.course, required this.baseUrl, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = course['cleanedName'] as String? ?? course['name'] as String? ?? 'Untitled';
    final photoPath = course['photo'] as String?;
    final photoUrl = photoPath != null && photoPath.isNotEmpty ? '$baseUrl$photoPath' : null;

    return FocusableButton(
      onPressed: onTap,
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: photoUrl != null
                    ? Image.network(photoUrl, fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => _placeholder(theme))
                    : _placeholder(theme),
              ),
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _placeholder(ThemeData theme) {
    return Container(
      color: theme.colorScheme.surfaceContainerHighest,
      child: const Icon(Symbols.school_rounded, size: 40, color: Colors.white38),
    );
  }
}

// ── Course Detail ────────────────────────────────────────────────────────────

class VidyaCourseDetailScreen extends StatefulWidget {
  final VidyaBrowseClient client;
  final Map<String, dynamic> course;
  final VidyaAccountConnection connection;

  const VidyaCourseDetailScreen({
    super.key,
    required this.client,
    required this.course,
    required this.connection,
  });

  @override
  State<VidyaCourseDetailScreen> createState() => _VidyaCourseDetailScreenState();
}

class _VidyaCourseDetailScreenState extends State<VidyaCourseDetailScreen> {
  Map<String, dynamic>? _detail;
  String? _error;
  bool _loading = true;
  final Set<String> _expanded = {};

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final courseId = widget.course['id'] as String?;
      if (courseId == null) throw Exception('Course has no ID');
      final data = await widget.client.fetchCourseDetail(courseId);
      if (mounted) {
        setState(() {
          _detail = data;
          // Auto-expand first section.
          final sections = (data['course']?['sections'] as List?)?.cast<Map<String, dynamic>>() ?? [];
          if (sections.isNotEmpty) _expanded.add(sections.first['id'] as String? ?? '');
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _playLecture(String courseId, String lectureId, String lectureName) async {
    final session = VidyaPlaybackSession(
      baseUrl: widget.connection.baseUrl,
      token: widget.connection.accessToken,
      courseId: courseId,
      lectureId: lectureId,
    );
    if (!mounted) return;
    context.read<VidyaSessionProvider>().setSession(session);

    final streamUrl = widget.client.streamUrl(lectureId);

    // Build a minimal PlaybackContext with the direct stream URL.
    // reportingClient is null so watch-state reporting is silently skipped.
    final playbackContext = PlaybackContext(
      // Use a PlexMediaItem as a carrier — backend is only used to decide
      // whether Plex-specific seek offsets apply (they don't for direct play).
      metadata: MediaItem(
        id: lectureId,
        backend: MediaBackend.plex,
        kind: MediaKind.episode,
        title: lectureName,
      ),
      result: PlaybackInitializationResult(
        availableVersions: const [],
        videoUrl: streamUrl,
      ),
      sourceKind: PlaybackSourceKind.remoteDirect,
      reportingMode: PlaybackReportingMode.disabled,
    );

    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => VideoPlayerScreen(
          metadata: playbackContext.metadata,
          prebuiltPlaybackFuture: Future.value(playbackContext),
        ),
        settings: const RouteSettings(name: kVideoPlayerRouteName),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final courseName = widget.course['cleanedName'] as String?
        ?? widget.course['name'] as String?
        ?? 'Course';

    return FocusedScrollScaffold(
      title: Text(courseName),
      slivers: [
        if (_loading)
          const SliverFillRemaining(child: Center(child: CircularProgressIndicator()))
        else if (_error != null)
          SliverFillRemaining(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Symbols.error_outline_rounded, size: 48, color: theme.colorScheme.error),
                    const SizedBox(height: 12),
                    Text(_error!, textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                    FocusableButton(
                      onPressed: _load,
                      child: FilledButton(onPressed: _load, child: const Text('Retry')),
                    ),
                  ],
                ),
              ),
            ),
          )
        else
          _buildContent(theme),
      ],
    );
  }

  Widget _buildContent(ThemeData theme) {
    final courseData = _detail?['course'] as Map<String, dynamic>?;
    if (courseData == null) {
      return const SliverFillRemaining(child: Center(child: Text('No course data.')));
    }

    final courseId = courseData['id'] as String? ?? widget.course['id'] as String? ?? '';
    final sections = (courseData['sections'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final description = courseData['description'] as String?;
    final duration = courseData['duration'] as num?;

    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      sliver: SliverList(
        delegate: SliverChildListDelegate([
          if (description != null && description.isNotEmpty) ...[
            Text(description, style: theme.textTheme.bodyMedium),
            const SizedBox(height: 12),
          ],
          if (duration != null)
            Text(
              _formatDuration(duration.toInt()),
              style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          const SizedBox(height: 16),
          Text('Course Content', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          for (final section in sections)
            _SectionTile(
              section: section,
              courseId: courseId,
              isExpanded: _expanded.contains(section['id'] as String? ?? ''),
              onToggle: () {
                final id = section['id'] as String? ?? '';
                setState(() {
                  if (_expanded.contains(id)) {
                    _expanded.remove(id);
                  } else {
                    _expanded.add(id);
                  }
                });
              },
              onPlayLecture: _playLecture,
            ),
        ]),
      ),
    );
  }

  String _formatDuration(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    if (h > 0) return '${h}h ${m}m total';
    return '${m}m total';
  }
}

class _SectionTile extends StatelessWidget {
  final Map<String, dynamic> section;
  final String courseId;
  final bool isExpanded;
  final VoidCallback onToggle;
  final Future<void> Function(String courseId, String lectureId, String lectureName) onPlayLecture;

  const _SectionTile({
    required this.section,
    required this.courseId,
    required this.isExpanded,
    required this.onToggle,
    required this.onPlayLecture,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = section['cleanedName'] as String? ?? 'Section';
    final lectures = (section['lectures'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final duration = section['duration'] as num?;
    final durationStr = duration != null ? _formatSeconds(duration.toInt()) : '';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FocusableButton(
          onPressed: onToggle,
          child: Card(
            margin: const EdgeInsets.only(bottom: 2),
            child: ListTile(
              onTap: onToggle,
              leading: Icon(
                isExpanded ? Symbols.expand_less_rounded : Symbols.expand_more_rounded,
                size: 20,
              ),
              title: Text(title, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
              trailing: durationStr.isNotEmpty
                  ? Text(
                      '$durationStr · ${lectures.length} lectures',
                      style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    )
                  : null,
            ),
          ),
        ),
        if (isExpanded)
          for (final lecture in lectures)
            _LectureTile(
              lecture: lecture,
              courseId: courseId,
              sectionOrder: section['order'] as int? ?? 0,
              onPlay: onPlayLecture,
            ),
      ],
    );
  }

  String _formatSeconds(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    if (h > 0) return '${h}h ${m.toString().padLeft(2, '0')}m';
    return '${m}:${(seconds % 60).toString().padLeft(2, '0')}';
  }
}

class _LectureTile extends StatelessWidget {
  final Map<String, dynamic> lecture;
  final String courseId;
  final int sectionOrder;
  final Future<void> Function(String courseId, String lectureId, String lectureName) onPlay;

  const _LectureTile({
    required this.lecture,
    required this.courseId,
    required this.sectionOrder,
    required this.onPlay,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lectureId = lecture['id'] as String?;
    final name = lecture['cleanedName'] as String? ?? 'Lecture';
    final order = lecture['order'] as int? ?? 0;
    final type = (lecture['type'] as String? ?? 'video').toLowerCase();
    final duration = lecture['duration'] as num?;
    final durationStr = duration != null && duration > 0 && type == 'video'
        ? _formatSeconds(duration.toInt())
        : '';

    return FocusableButton(
      onPressed: lectureId != null ? () => unawaited(onPlay(courseId, lectureId, name)) : null,
      child: ListTile(
        contentPadding: const EdgeInsets.only(left: 32, right: 16),
        onTap: lectureId != null ? () => unawaited(onPlay(courseId, lectureId, name)) : null,
        leading: Icon(
          type == 'video' ? Symbols.play_circle_rounded : Symbols.description_rounded,
          size: 20,
          color: theme.colorScheme.primary,
        ),
        title: Text(
          '$sectionOrder.$order: $name',
          style: theme.textTheme.bodySmall,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: durationStr.isNotEmpty
            ? Text(durationStr, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant))
            : null,
      ),
    );
  }

  String _formatSeconds(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    if (h > 0) return '${h}h ${m.toString().padLeft(2, '0')}m';
    return '${m}:${s.toString().padLeft(2, '0')}';
  }
}
