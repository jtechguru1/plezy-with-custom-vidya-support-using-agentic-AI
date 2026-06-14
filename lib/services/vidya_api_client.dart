import 'dart:convert';
import 'package:http/http.dart' as http;

import 'vidya_connection.dart';

class VidyaApiClient {
  final VidyaConnection connection;

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

  Future<http.Response> uploadFile(String fileName, List<int> bytes, String mimeType) async {
    final uri = Uri.parse('${connection.baseUrl}/api/course/uploads/${connection.lectureId}');
    final request = http.MultipartRequest('POST', uri)
      ..headers['Authorization'] = 'Bearer ${connection.token}'
      ..files.add(http.MultipartFile.fromBytes('file', bytes, filename: fileName));
    final streamed = await request.send();
    return http.Response.fromStream(streamed);
  }

  String contentUrl(String pathId) =>
      '${connection.baseUrl}/api/course/content/$pathId?token=${connection.token}';

  String uploadFileUrl(String uploadId) =>
      '${connection.baseUrl}/api/course/uploads/file/$uploadId';
}
