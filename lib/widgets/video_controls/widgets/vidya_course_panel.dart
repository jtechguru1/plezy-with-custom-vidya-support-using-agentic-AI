import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../services/vidya_api_client.dart';
import '../../../services/vidya_connection.dart';
import '../../../utils/platform_detector.dart';

class VidyaCoursePanel extends StatefulWidget {
  final VidyaPlaybackSession connection;

  const VidyaCoursePanel({super.key, required this.connection});

  @override
  State<VidyaCoursePanel> createState() => _VidyaCoursePanelState();
}

class _VidyaCoursePanelState extends State<VidyaCoursePanel>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  late final VidyaApiClient _api;

  Map<String, dynamic>? _courseData;
  List<Map<String, dynamic>>? _uploads;
  String? _courseError;
  String? _uploadsError;
  bool _loadingCourse = true;
  bool _loadingUploads = false;
  bool _isTV = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _api = VidyaApiClient(widget.connection);
    _isTV = PlatformDetector.isTV();
    _tabController.addListener(_onTabChanged);
    unawaited(_loadCourse());
  }

  @override
  void dispose() {
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    super.dispose();
  }

  void _onTabChanged() {
    if (_tabController.index == 2 && _uploads == null && !_loadingUploads) {
      unawaited(_loadUploads());
    }
  }

  Future<void> _loadCourse() async {
    setState(() {
      _loadingCourse = true;
      _courseError = null;
    });
    try {
      final data = await _api.fetchCourse();
      if (mounted) setState(() => _courseData = data);
    } catch (e) {
      if (mounted) setState(() => _courseError = e.toString());
    } finally {
      if (mounted) setState(() => _loadingCourse = false);
    }
  }

  Future<void> _loadUploads() async {
    setState(() {
      _loadingUploads = true;
      _uploadsError = null;
    });
    try {
      final data = await _api.fetchUploads();
      if (mounted) setState(() => _uploads = data);
    } catch (e) {
      if (mounted) setState(() => _uploadsError = e.toString());
    } finally {
      if (mounted) setState(() => _loadingUploads = false);
    }
  }

  Future<void> _deleteUpload(String uploadId) async {
    try {
      await _api.deleteUpload(uploadId);
      if (mounted) {
        setState(() => _uploads?.removeWhere((u) => u['id'] == uploadId));
      }
    } catch (_) {}
  }

  List<Map<String, dynamic>> get _currentLectureResources {
    final course = _courseData?['course'];
    if (course == null) return [];
    final sections = (course['sections'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    for (final section in sections) {
      final lectures = (section['lectures'] as List?)?.cast<Map<String, dynamic>>() ?? [];
      for (final lecture in lectures) {
        if (lecture['id'] == widget.connection.lectureId) {
          return (lecture['content'] as List?)?.cast<Map<String, dynamic>>() ?? [];
        }
      }
    }
    return [];
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.82),
        border: const Border(left: BorderSide(color: Colors.white12)),
      ),
      child: Column(
        children: [
          _buildTabBar(),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildCourseContentTab(),
                _buildResourcesTab(),
                _buildUserUploadsTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabBar() {
    return Container(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Colors.white12)),
      ),
      child: TabBar(
        controller: _tabController,
        isScrollable: true,
        tabAlignment: TabAlignment.start,
        labelStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        unselectedLabelStyle: const TextStyle(fontSize: 12),
        labelColor: Colors.white,
        unselectedLabelColor: Colors.white54,
        indicatorColor: Colors.white,
        indicatorWeight: 2,
        dividerColor: Colors.transparent,
        tabs: const [
          Tab(text: 'Course Content'),
          Tab(text: 'Resources'),
          Tab(text: 'User Uploads'),
        ],
      ),
    );
  }

  // ── Course Content ──────────────────────────────────────────────────────────

  Widget _buildCourseContentTab() {
    if (_loadingCourse) {
      return const Center(child: CircularProgressIndicator(color: Colors.white54, strokeWidth: 2));
    }
    if (_courseError != null) {
      return _buildError(_courseError!, _loadCourse);
    }
    final course = _courseData?['course'];
    if (course == null) return const SizedBox.shrink();

    final sections = (course['sections'] as List?)?.cast<Map<String, dynamic>>() ?? [];

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: sections.length,
      itemBuilder: (context, si) {
        final section = sections[si];
        final lectures = (section['lectures'] as List?)?.cast<Map<String, dynamic>>() ?? [];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
              child: Text(
                section['cleanedName'] as String? ?? '',
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            ...lectures.map((lecture) => _buildLectureRow(lecture)),
          ],
        );
      },
    );
  }

  Widget _buildLectureRow(Map<String, dynamic> lecture) {
    final isCurrent = lecture['id'] == widget.connection.lectureId;
    final duration = lecture['duration'] as num?;
    final durationStr = duration != null && duration > 0
        ? _formatSeconds(duration.toInt())
        : '';

    return Container(
      color: isCurrent ? Colors.white.withValues(alpha: 0.08) : null,
      child: ListTile(
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
        focusColor: Colors.white.withValues(alpha: 0.12),
        onTap: () {},
        leading: Icon(
          Symbols.play_circle_rounded,
          color: isCurrent ? Colors.white : Colors.white38,
          size: 18,
        ),
        title: Text(
          lecture['cleanedName'] as String? ?? '',
          style: TextStyle(
            color: isCurrent ? Colors.white : Colors.white70,
            fontSize: 12,
            fontWeight: isCurrent ? FontWeight.w600 : FontWeight.normal,
          ),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: durationStr.isNotEmpty
            ? Text(
                durationStr,
                style: const TextStyle(color: Colors.white38, fontSize: 11),
              )
            : null,
      ),
    );
  }

  // ── Resources ───────────────────────────────────────────────────────────────

  Widget _buildResourcesTab() {
    if (_loadingCourse) {
      return const Center(child: CircularProgressIndicator(color: Colors.white54, strokeWidth: 2));
    }
    if (_courseError != null) {
      return _buildError(_courseError!, _loadCourse);
    }

    final resources = _currentLectureResources;
    if (resources.isEmpty) {
      return _buildEmpty('No resources for this lecture');
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: resources.length,
      itemBuilder: (context, i) {
        final resource = resources[i];
        final name = resource['cleanedName'] as String? ??
            resource['originalName'] as String? ??
            'File';
        final pathId = resource['pathId'] as String?;

        return ListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12),
          focusColor: Colors.white.withValues(alpha: 0.12),
          onTap: () {},
          leading: Icon(
            _fileIcon(resource['type'] as String?),
            color: Colors.white54,
            size: 18,
          ),
          title: Text(
            name,
            style: const TextStyle(color: Colors.white, fontSize: 12),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: _isTV || pathId == null
              ? null
              : IconButton(
                  icon: const Icon(Symbols.download_rounded, color: Colors.white54, size: 18),
                  tooltip: 'Download',
                  onPressed: () => unawaited(
                    launchUrl(Uri.parse(_api.contentUrl(pathId)),
                        mode: LaunchMode.externalApplication),
                  ),
                ),
        );
      },
    );
  }

  // ── User Uploads ─────────────────────────────────────────────────────────────

  Widget _buildUserUploadsTab() {
    if (_uploadsError != null && !_loadingUploads) {
      return _buildError(_uploadsError!, _loadUploads);
    }
    if (_loadingUploads || _uploads == null) {
      return const Center(child: CircularProgressIndicator(color: Colors.white54, strokeWidth: 2));
    }

    return Column(
      children: [
        Expanded(
          child: _uploads!.isEmpty
              ? _buildEmpty('No uploads for this lecture')
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: _uploads!.length,
                  itemBuilder: (context, i) => _buildUploadRow(_uploads![i]),
                ),
        ),
      ],
    );
  }

  Widget _buildUploadButton() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      child: SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.white70,
            side: const BorderSide(color: Colors.white24),
            padding: const EdgeInsets.symmetric(vertical: 8),
          ),
          icon: const Icon(Symbols.upload_file_rounded, size: 16),
          label: const Text('Upload File', style: TextStyle(fontSize: 12)),
          onPressed: () {
            // Phase 2: wire file_picker here
          },
        ),
      ),
    );
  }

  Widget _buildUploadRow(Map<String, dynamic> upload) {
    final name = upload['originalName'] as String? ?? 'File';
    final size = upload['fileSize'] as num?;
    final sizeStr = size != null ? _formatBytes(size.toInt()) : '';
    final uploadId = upload['id'] as String?;

    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12),
      leading: const Icon(Symbols.attach_file_rounded, color: Colors.white54, size: 18),
      title: Text(
        name,
        style: const TextStyle(color: Colors.white, fontSize: 12),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: sizeStr.isNotEmpty
          ? Text(sizeStr, style: const TextStyle(color: Colors.white38, fontSize: 10))
          : null,
      trailing: uploadId == null
          ? null
          : Row(
              mainAxisSize: .min,
              children: [
                if (!_isTV)
                  IconButton(
                    icon: const Icon(Symbols.download_rounded, color: Colors.white54, size: 18),
                    tooltip: 'Download',
                    onPressed: () => unawaited(
                      launchUrl(Uri.parse(_api.uploadFileUrl(uploadId)),
                          mode: LaunchMode.externalApplication),
                    ),
                  ),
                IconButton(
                  icon: const Icon(Symbols.delete_rounded, color: Colors.white38, size: 18),
                  tooltip: 'Delete',
                  onPressed: () => _deleteUpload(uploadId),
                ),
              ],
            ),
    );
  }

  // ── Helpers ─────────────────────────────────────────────────────────────────

  Widget _buildError(String message, Future<void> Function() retry) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: .min,
          children: [
            const Icon(Symbols.error_outline_rounded, color: Colors.white38, size: 32),
            const SizedBox(height: 8),
            Text(
              message,
              style: const TextStyle(color: Colors.white54, fontSize: 12),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => unawaited(retry()),
              child: const Text('Retry', style: TextStyle(color: Colors.white70, fontSize: 12)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmpty(String message) {
    return Center(
      child: Text(
        message,
        style: const TextStyle(color: Colors.white38, fontSize: 12),
        textAlign: TextAlign.center,
      ),
    );
  }

  IconData _fileIcon(String? type) {
    switch (type?.toLowerCase()) {
      case 'pdf':
        return Symbols.picture_as_pdf_rounded;
      case 'mp3':
      case 'wav':
      case 'aac':
        return Symbols.audio_file_rounded;
      case 'jpg':
      case 'jpeg':
      case 'png':
      case 'gif':
        return Symbols.image_rounded;
      case 'zip':
      case 'rar':
      case '7z':
        return Symbols.folder_zip_rounded;
      default:
        return Symbols.description_rounded;
    }
  }

  String _formatSeconds(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    if (h > 0) {
      return '${h}h ${m.toString().padLeft(2, '0')}m';
    }
    return '${m}:${s.toString().padLeft(2, '0')}';
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)}GB';
  }
}
