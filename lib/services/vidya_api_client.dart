import 'dart:convert';
import 'package:http/http.dart' as http;

import 'vidya_connection.dart';

class VidyaApiClient {
  final VidyaPlaybackSession connection;

  VidyaApiClient(this.connection);

  Map<String, String> get _headers => {
        'Authorization': 'Bearer ${connection.token}',
        'Content-Type': 'application/json',
      };

  Future<Map<String, dynamic>> fetchCourse() async {
    final uri = Uri.parse('${connection.baseUrl}/api/course/${connection.courseId}');
    final response = await http.get(uri, headers: _headers);
    if (response.statusCode != 200) {
      throw Exception('Failed to fetch course: ${response.statusCode}');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  /// Fetches course data via POST /player which includes each lecture's
  /// `content` (resource files). The GET endpoint omits `content`.
  /// Returns the same shape as [fetchCourse]: `{ course: {...} }`.
  Future<Map<String, dynamic>> fetchCourseWithContent() async {
    final uri = Uri.parse('${connection.baseUrl}/api/course/player');
    final response = await http.post(
      uri,
      headers: _headers,
      body: jsonEncode({'CourseId': connection.courseId}),
    );
    if (response.statusCode != 200) {
      throw Exception('Failed to fetch course: ${response.statusCode}');
    }
    // Response is [courseObject, deflangObject]
    final list = jsonDecode(response.body) as List;
    return {'course': list[0] as Map<String, dynamic>};
  }

  Future<List<Map<String, dynamic>>> fetchUploads() async {
    final uri = Uri.parse('${connection.baseUrl}/api/course/uploads/${connection.lectureId}');
    final response = await http.get(uri, headers: _headers);
    if (response.statusCode != 200) {
      throw Exception('Failed to fetch uploads: ${response.statusCode}');
    }
    return (jsonDecode(response.body) as List).cast<Map<String, dynamic>>();
  }

  Future<void> deleteUpload(String uploadId) async {
    final uri = Uri.parse('${connection.baseUrl}/api/course/uploads/$uploadId');
    final response = await http.delete(uri, headers: _headers);
    if (response.statusCode != 204) {
      throw Exception('Failed to delete upload: ${response.statusCode}');
    }
  }

  String contentUrl(String pathId) =>
      '${connection.baseUrl}/api/course/content/$pathId?token=${connection.token}';

  String uploadFileUrl(String uploadId) =>
      '${connection.baseUrl}/api/course/uploads/file/$uploadId';

  /// Syncs the current playback position to `POST /api/v1/progress/sync`.
  /// [timeSeconds] is the current player position. [isCompleted] marks the
  /// lecture finished. Throws on non-200 so callers can queue offline.
  Future<void> syncProgress({
    required double timeSeconds,
    required bool isCompleted,
  }) async {
    final uri = Uri.parse('${connection.baseUrl}/api/v1/progress/sync');
    final response = await http.post(
      uri,
      headers: _headers,
      body: jsonEncode({
        'course_id': connection.courseId,
        'lesson_id': connection.lectureId,
        'time_seconds': timeSeconds,
        'is_completed': isCompleted,
      }),
    );
    if (response.statusCode != 200) {
      throw Exception('Progress sync failed: ${response.statusCode}');
    }
  }
}

/// Lightweight client for browsing VIDYA courses before a playback session
/// is established. Uses [VidyaAccountConnection] credentials.
class VidyaBrowseClient {
  final String baseUrl;
  final String accessToken;

  const VidyaBrowseClient({required this.baseUrl, required this.accessToken});

  Map<String, String> get _headers => {
        'Authorization': 'Bearer $accessToken',
        'Content-Type': 'application/json',
      };

  Future<List<Map<String, dynamic>>> fetchCourses() async {
    final uri = Uri.parse('$baseUrl/api/course');
    final response = await http.get(uri, headers: _headers);
    if (response.statusCode != 200) {
      throw Exception('Failed to fetch courses: ${response.statusCode}');
    }
    return (jsonDecode(response.body) as List).cast<Map<String, dynamic>>();
  }

  Future<Map<String, dynamic>> fetchCourseDetail(String courseId) async {
    final uri = Uri.parse('$baseUrl/api/course/$courseId');
    final response = await http.get(uri, headers: _headers);
    if (response.statusCode != 200) {
      throw Exception('Failed to fetch course: ${response.statusCode}');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  String streamUrl(String lectureId) =>
      '$baseUrl/api/course/stream/$lectureId?token=$accessToken';

  /// Fetches the full course outline with per-user completion state.
  /// Used by [VidyaCoursePlayerView] to populate the sidebar.
  Future<Map<String, dynamic>> fetchOutline(String courseId) async {
    final uri = Uri.parse('$baseUrl/api/v1/courses/$courseId/outline');
    final response = await http.get(uri, headers: _headers);
    if (response.statusCode != 200) {
      throw Exception('Failed to fetch outline: ${response.statusCode}');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }
}
