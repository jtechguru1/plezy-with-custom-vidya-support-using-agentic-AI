import 'dart:async';

import 'package:flutter/material.dart';

import '../../../services/vidya_api_client.dart';
import '../../../services/vidya_connection.dart';

/// Displays the resource files attached to the currently playing VIDYA lecture.
/// Read-only — no download or interaction; intended for TV/controller viewing.
class VidyaLectureResources extends StatefulWidget {
  final VidyaPlaybackSession session;

  const VidyaLectureResources({super.key, required this.session});

  @override
  State<VidyaLectureResources> createState() => _VidyaLectureResourcesState();
}

class _VidyaLectureResourcesState extends State<VidyaLectureResources> {
  List<String>? _resourceNames;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(VidyaLectureResources old) {
    super.didUpdateWidget(old);
    if (old.session.lectureId != widget.session.lectureId ||
        old.session.courseId != widget.session.courseId ||
        old.session.baseUrl != widget.session.baseUrl) {
      setState(() {
        _loading = true;
        _resourceNames = null;
      });
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    try {
      final api = VidyaApiClient(widget.session);
      final data = await api.fetchCourseWithContent();
      final course = data['course'];
      if (course == null) {
        if (mounted) setState(() { _resourceNames = []; _loading = false; });
        return;
      }
      final sections = (course['sections'] as List?)?.cast<Map<String, dynamic>>() ?? [];
      for (final section in sections) {
        final lectures = (section['lectures'] as List?)?.cast<Map<String, dynamic>>() ?? [];
        for (final lecture in lectures) {
          if (lecture['id'] == widget.session.lectureId) {
            final content = (lecture['content'] as List?)?.cast<Map<String, dynamic>>() ?? [];
            final names = content.map((r) {
              final cleaned = r['cleanedName'] as String? ?? '';
              final original = r['originalName'] as String?;
              final type = r['type'] as String?;
              if (cleaned.isNotEmpty && type != null && type.isNotEmpty) {
                return '$cleaned.$type';
              }
              if (original != null && original.isNotEmpty) return original;
              return cleaned.isNotEmpty ? cleaned : 'File';
            }).toList();
            if (mounted) setState(() { _resourceNames = names; _loading = false; });
            return;
          }
        }
      }
      if (mounted) setState(() { _resourceNames = []; _loading = false; });
    } catch (_) {
      if (mounted) setState(() { _resourceNames = []; _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        color: Color(0xCC000000),
        border: Border(top: BorderSide(color: Colors.white12)),
      ),
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 8),
      child: Column(
        children: [
          const Text(
            'Resources',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 6),
          const Divider(color: Colors.white24, height: 1),
          const SizedBox(height: 8),
          if (_loading)
            const Expanded(
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(color: Colors.white38, strokeWidth: 2),
                ),
              ),
            )
          else if (_resourceNames == null || _resourceNames!.isEmpty)
            const Expanded(
              child: Center(
                child: Text(
                  'No resources for this lesson',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white38, fontSize: 12),
                ),
              ),
            )
          else
            Expanded(
              child: ListView(
                padding: EdgeInsets.zero,
                children: _resourceNames!
                    .map(
                      (name) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Text(
                          name,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white70, fontSize: 12),
                        ),
                      ),
                    )
                    .toList(),
              ),
            ),
        ],
      ),
    );
  }
}
