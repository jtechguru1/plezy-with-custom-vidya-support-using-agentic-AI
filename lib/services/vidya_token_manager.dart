import 'dart:convert';

import 'package:http/http.dart' as http;

import '../connection/connection.dart';
import '../connection/connection_registry.dart';

/// Wraps HTTP requests for VIDYA with automatic JWT refresh.
///
/// On a 401 response the manager calls POST /api/auth/refresh once, stores
/// the new tokens, persists them back to [ConnectionRegistry], then retries
/// the original request. Callers get a transparent single-retry — they never
/// need to handle token expiry themselves.
///
/// After any successful refresh, [accessToken] reflects the new value so
/// callers that build non-HTTP URLs (e.g. stream URLs with ?token=) can read
/// the latest token directly.
class VidyaTokenManager {
  final String baseUrl;
  final String _connectionId;
  final ConnectionRegistry _registry;

  String _accessToken;
  String _refreshToken;

  String get accessToken => _accessToken;

  VidyaTokenManager({
    required this.baseUrl,
    required String connectionId,
    required String accessToken,
    required String refreshToken,
    required ConnectionRegistry registry,
  })  : _connectionId = connectionId,
        _accessToken = accessToken,
        _refreshToken = refreshToken,
        _registry = registry;

  factory VidyaTokenManager.fromConnection(
    VidyaAccountConnection connection,
    ConnectionRegistry registry,
  ) {
    return VidyaTokenManager(
      baseUrl: connection.baseUrl,
      connectionId: connection.id,
      accessToken: connection.accessToken,
      refreshToken: connection.refreshToken,
      registry: registry,
    );
  }

  Map<String, String> get _authHeaders => {
        'Authorization': 'Bearer $_accessToken',
        'Content-Type': 'application/json',
      };

  Future<http.Response> get(Uri uri) async {
    var response = await http.get(uri, headers: _authHeaders);
    if (response.statusCode == 401 && _refreshToken.isNotEmpty) {
      await _doRefresh();
      response = await http.get(uri, headers: _authHeaders);
    }
    return response;
  }

  Future<http.Response> post(Uri uri, {Object? body}) async {
    var response = await http.post(uri, headers: _authHeaders, body: body);
    if (response.statusCode == 401 && _refreshToken.isNotEmpty) {
      await _doRefresh();
      response = await http.post(uri, headers: _authHeaders, body: body);
    }
    return response;
  }

  Future<void> _doRefresh() async {
    final uri = Uri.parse('$baseUrl/api/auth/refresh');
    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'refreshToken': _refreshToken}),
    );
    if (response.statusCode != 200) {
      throw Exception('Session expired — please sign in again (${response.statusCode})');
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final newAccessToken = json['token'] as String? ?? '';
    final newRefreshToken = json['refreshToken'] as String? ?? '';
    if (newAccessToken.isEmpty) throw Exception('Refresh returned no token');

    _accessToken = newAccessToken;
    if (newRefreshToken.isNotEmpty) _refreshToken = newRefreshToken;

    final existing = await _registry.get(_connectionId);
    if (existing is VidyaAccountConnection) {
      await _registry.upsert(existing.copyWith(
        accessToken: _accessToken,
        refreshToken: _refreshToken,
        lastAuthenticatedAt: DateTime.now(),
      ));
    }
  }
}
