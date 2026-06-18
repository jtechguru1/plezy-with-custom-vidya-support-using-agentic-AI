import 'dart:convert';

import 'package:http/http.dart' as http;

import '../connection/connection.dart';
import '../media/download_resolution.dart';
import '../media/ids.dart';
import '../media/library_filter_result.dart';
import '../media/library_first_character.dart';
import '../media/library_query.dart';
import '../media/live_tv_support.dart';
import '../media/media_backend.dart';
import '../media/media_file_info.dart';
import '../media/media_hub.dart';
import '../media/media_item.dart';
import '../media/media_kind.dart';
import '../media/media_playlist.dart';
import '../media/media_library.dart';
import '../media/media_server_client.dart';
import '../media/media_sort.dart';
import '../media/media_source_info.dart';
import '../media/playback_report_metadata.dart';
import '../media/server_capabilities.dart';
import '../utils/external_ids.dart';
import '../utils/media_server_http_client.dart' show AbortController;
import 'api_cache.dart';
import 'playback_initialization_types.dart';
import 'scrub_preview_source.dart';
import 'vidya_token_manager.dart';

/// [MediaServerClient] stub for a VIDYA server.
///
/// Only implements the methods called by [DiscoverProvider] /
/// [DataAggregationService] for the home screen path:
///   - [checkHealth]
///   - [fetchContinueWatching]
///   - [fetchGlobalHubs]
///   - [thumbnailUrl]
///
/// All other interface methods throw [UnsupportedError] — they are never
/// invoked for VIDYA items because [media_navigation_helper.dart] intercepts
/// navigation before any Plex/Jellyfin-specific playback code runs.
class VidyaMediaServerClient extends MediaServerClient {
  final VidyaAccountConnection _connection;
  final VidyaTokenManager _tokenManager;
  bool _offline = false;

  VidyaMediaServerClient(this._connection, this._tokenManager);

  // In-flight deduplication + 30-second TTL cache for /api/v1/home.
  // Both fetchContinueWatching and fetchGlobalHubs call _fetchHome; without
  // this they fire two serial requests per home refresh cycle.
  Future<Map<String, dynamic>>? _pendingHomeFetch;
  Map<String, dynamic>? _homeCache;
  DateTime? _homeCacheTime;
  static const _homeCacheTtl = Duration(seconds: 30);

  @override
  ServerId get serverId => ServerId(_connection.id);

  @override
  String? get serverName {
    final cached = _homeCache?['server_name'] as String?;
    if (cached != null && cached.isNotEmpty) return cached;
    return _connection.serverName;
  }

  @override
  MediaBackend get backend => MediaBackend.vidya;

  @override
  ServerCapabilities get capabilities => const ServerCapabilities(richHubs: true);

  @override
  bool get isOfflineMode => _offline;

  @override
  void setOfflineMode(bool offline) => _offline = offline;

  @override
  ApiCache get cache => throw UnsupportedError('VidyaMediaServerClient has no ApiCache');

  @override
  Map<String, String> get streamHeaders => const {};

  @override
  void close() {}

  @override
  Future<HealthStatus> checkHealth() async {
    try {
      final uri = Uri.parse('${_connection.baseUrl}/isFirstStartUp');
      final response = await http.get(uri).timeout(const Duration(seconds: 10));
      return response.statusCode == 200 ? HealthStatus.online : HealthStatus.offline;
    } catch (_) {
      return HealthStatus.offline;
    }
  }

  @override
  Future<String?> getMachineIdentifier() async => _connection.id;

  @override
  Future<List<MediaItem>> fetchContinueWatching({int? count = 20}) async {
    final data = await _fetchHome();
    final raw = (data['continue_watching'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    return raw.map((e) => _lectureToMediaItem(e)).toList();
  }

  @override
  Future<List<MediaHub>> fetchGlobalHubs({
    int limit = defaultHubPreviewLimit,
    bool includePlaybackHubs = true,
  }) async {
    final data = await _fetchHome();
    final rawHubs = (data['hubs'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    if (rawHubs.isNotEmpty) {
      return rawHubs.map((hub) {
        final items = ((hub['items'] as List?)?.cast<Map<String, dynamic>>() ?? [])
            .map((e) => _courseToMediaItem(e))
            .take(limit)
            .toList();
        return MediaHub(
          id: hub['id'] as String? ?? '',
          identifier: hub['id'] as String?,
          title: hub['title'] as String? ?? 'Courses',
          type: 'show',
          items: items,
          size: items.length,
          more: false,
          serverId: _connection.id,
          serverName: _connection.serverName,
        );
      }).toList();
    }

    return [];
  }

  @override
  String thumbnailUrl(String? path, {int? width, int? height}) {
    if (path == null || path.isEmpty) return '';
    if (path.startsWith('http')) return path;
    return '${_connection.baseUrl}$path?token=${_tokenManager.accessToken}';
  }

  @override
  String externalImageUrl(String url, {int? width, int? height}) => url;

  /// Clears the in-memory home cache so the next [fetchGlobalHubs] or
  /// [fetchContinueWatching] call hits the server instead of the 30-second TTL.
  void invalidateHomeCache() {
    _homeCache = null;
    _homeCacheTime = null;
    _pendingHomeFetch = null;
  }

  // ── Private helpers ────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> _fetchHome() {
    final now = DateTime.now();
    final cached = _homeCache;
    final cacheTime = _homeCacheTime;
    if (cached != null && cacheTime != null && now.difference(cacheTime) < _homeCacheTtl) {
      return Future.value(cached);
    }
    return _pendingHomeFetch ??= _doFetchHome().whenComplete(() => _pendingHomeFetch = null);
  }

  Future<Map<String, dynamic>> _doFetchHome() async {
    final uri = Uri.parse('${_connection.baseUrl}/api/v1/home');
    final response = await _tokenManager.get(uri);
    if (response.statusCode != 200) {
      throw Exception('Failed to load VIDYA home: ${response.statusCode}');
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    _homeCache = data;
    _homeCacheTime = DateTime.now();
    return data;
  }

  MediaItem _lectureToMediaItem(Map<String, dynamic> e) {
    final watchTimeSec = (e['watch_time'] as num?)?.toDouble() ?? 0.0;
    final durationSec = (e['lecture_duration'] as num?)?.toDouble() ?? 0.0;
    final updatedDt = e['updated_at'] != null
        ? DateTime.tryParse(e['updated_at'].toString())
        : null;
    final updatedAt = updatedDt != null ? updatedDt.millisecondsSinceEpoch ~/ 1000 : null;
    return MediaItem.vidya(
      id: e['lecture_id'] as String? ?? '',
      kind: MediaKind.episode,
      title: e['lecture_title'] as String?,
      grandparentId: e['course_id'] as String?,
      grandparentTitle: e['course_title'] as String?,
      grandparentThumbPath: e['course_photo'] != null
          ? thumbnailUrl(e['course_photo'] as String)
          : null,
      parentId: e['section_id'] as String?,
      durationMs: durationSec > 0 ? (durationSec * 1000).round() : null,
      viewOffsetMs: watchTimeSec > 0 ? (watchTimeSec * 1000).round() : null,
      lastViewedAt: updatedAt,
      serverId: _connection.id,
      serverName: _connection.serverName,
    );
  }

  MediaItem _courseToMediaItem(Map<String, dynamic> e) {
    final addedDt = e['added_at'] != null
        ? DateTime.tryParse(e['added_at'].toString())
        : null;
    final addedAt = addedDt != null ? addedDt.millisecondsSinceEpoch ~/ 1000 : null;
    final dur = (e['duration'] as num?)?.toDouble() ?? 0.0;
    return MediaItem.vidya(
      id: e['course_id'] as String? ?? '',
      kind: MediaKind.movie,
      title: e['title'] as String?,
      thumbPath: e['photo'] != null ? thumbnailUrl(e['photo'] as String) : null,
      durationMs: dur > 0 ? (dur * 1000).round() : null,
      leafCount: (e['total_lectures'] as num?)?.toInt(),
      viewedLeafCount: (e['completed_lectures'] as num?)?.toInt(),
      addedAt: addedAt,
      serverId: _connection.id,
      serverName: _connection.serverName,
    );
  }

  // ── Unsupported stubs ──────────────────────────────────────────────────────

  @override
  LiveTvSupport get liveTv => _VidyaNullLiveTvSupport();

  @override
  Future<List<MediaLibrary>> fetchLibraries() async => [];

  @override
  Future<LibraryPage<MediaItem>> fetchLibraryContent(String libraryId, LibraryQuery query) =>
      throw UnsupportedError('VIDYA: fetchLibraryContent');

  @override
  Future<LibraryPage<MediaItem>> fetchLibraryPagedContent(
    String libraryId, {
    required LibraryQuery query,
    MediaKind? libraryKind,
    AbortController? abort,
  }) =>
      throw UnsupportedError('VIDYA: fetchLibraryPagedContent');

  @override
  Future<LibraryFilterResult> fetchLibraryFiltersWithValues(String libraryId) =>
      throw UnsupportedError('VIDYA: fetchLibraryFiltersWithValues');

  @override
  Future<List<MediaSort>> fetchSortOptions(String libraryId, {String? libraryType}) async => [];

  @override
  Future<List<LibraryFirstCharacter>> fetchFirstCharacters(
    String libraryId, {
    Map<String, String>? filters,
  }) async =>
      [];

  @override
  Future<void> refreshLibraryMetadata(String libraryId) async {}

  @override
  Future<MediaItem?> fetchItem(String id) async => null;

  @override
  Future<({MediaItem? item, MediaItem? onDeckEpisode})> fetchItemWithOnDeck(String id) async =>
      (item: null, onDeckEpisode: null);

  @override
  Future<List<MediaItem>> fetchChildren(String parentId) async => [];

  @override
  Future<List<MediaItem>> fetchLibraryFolders(
    String libraryId, {
    void Function(List<MediaItem> itemsSoFar)? onPage,
  }) async =>
      [];

  @override
  Future<List<MediaItem>> fetchFolderChildren(
    MediaItem folder, {
    String? libraryId,
    String? libraryTitle,
    void Function(List<MediaItem> itemsSoFar)? onPage,
  }) async =>
      [];

  @override
  Future<LibraryPage<MediaItem>> fetchChildrenPage(
    String parentId, {
    int? start,
    int? size,
    AbortController? abort,
  }) =>
      throw UnsupportedError('VIDYA: fetchChildrenPage');

  @override
  Future<LibraryPage<MediaItem>> fetchPlayableDescendantsPage(
    String parentId, {
    int? start,
    int? size,
    AbortController? abort,
  }) =>
      throw UnsupportedError('VIDYA: fetchPlayableDescendantsPage');

  @override
  Future<List<MediaItem>> fetchPlayableDescendants(String parentId) async => [];

  @override
  Future<List<MediaItem>?> fetchClientSideEpisodeQueue(String seriesId) async => null;

  @override
  Future<List<MediaItem>> searchItems(String query, {int limit = 100}) async => [];

  @override
  Future<List<MediaItem>> fetchRecentlyAdded({int limit = 50}) async => [];

  @override
  Future<List<MediaHub>> fetchLibraryHubs(
    String libraryId, {
    required String libraryName,
    int limit = defaultHubPreviewLimit,
    bool includePlaybackHubs = true,
    MediaKind? libraryKind,
  }) async =>
      [];

  @override
  Future<List<MediaHub>> fetchRelatedHubs(String id, {int count = 10}) async => [];

  @override
  Future<List<MediaItem>> fetchExtras(String id) async => [];

  @override
  Future<List<MediaItem>> fetchPersonMedia(String personId) async => [];

  @override
  Future<LibraryPage<MediaItem>> fetchPersonMediaPage(
    String personId, {
    int? start,
    int? size,
    AbortController? abort,
  }) =>
      throw UnsupportedError('VIDYA: fetchPersonMediaPage');

  @override
  Future<List<MediaItem>> fetchMoreHubItems(String hubId, {int? limit}) async => [];

  @override
  Future<LibraryPage<MediaItem>> fetchMoreHubItemsPage(
    String hubId, {
    int? start,
    int? size,
    AbortController? abort,
  }) =>
      throw UnsupportedError('VIDYA: fetchMoreHubItemsPage');

  @override
  Future<void> markWatched(MediaItem item) async {}

  @override
  Future<void> markUnwatched(MediaItem item) async {}

  @override
  Future<void> removeFromContinueWatching(MediaItem item) async {}

  @override
  Future<void> rate(MediaItem item, double rating) async {}

  @override
  Future<List<MediaPlaylist>> fetchPlaylists({String playlistType = 'video', bool? smart}) async => [];

  @override
  Future<LibraryPage<MediaPlaylist>> fetchPlaylistsPage({
    String playlistType = 'video',
    bool? smart,
    int? start,
    int? size,
    AbortController? abort,
  }) =>
      throw UnsupportedError('VIDYA: fetchPlaylistsPage');

  @override
  Future<MediaPlaylist?> fetchPlaylistMetadata(String id) async => null;

  @override
  Future<List<MediaItem>> fetchPlaylistItems(String id, {int offset = 0, int limit = 100}) async => [];

  @override
  Future<LibraryPage<MediaItem>> fetchPlaylistPage(
    String id, {
    int? start,
    int? size,
    AbortController? abort,
  }) =>
      throw UnsupportedError('VIDYA: fetchPlaylistPage');

  @override
  Future<MediaPlaylist?> createPlaylist({required String title, required List<MediaItem> items}) async => null;

  @override
  Future<bool> addToPlaylist({required String playlistId, required List<MediaItem> items}) async => false;

  @override
  Future<bool> deletePlaylist(MediaPlaylist playlist) async => false;

  @override
  Future<bool> movePlaylistItem({
    required String playlistId,
    required MediaItem item,
    required int newIndex,
    required MediaItem? afterItem,
  }) async =>
      false;

  @override
  Future<bool> removeFromPlaylist({required String playlistId, required MediaItem item}) async => false;

  @override
  Future<List<MediaItem>> fetchCollections(String libraryId) async => [];

  @override
  Future<LibraryPage<MediaItem>> fetchCollectionsPage(
    String libraryId, {
    int? start,
    int? size,
    AbortController? abort,
  }) =>
      throw UnsupportedError('VIDYA: fetchCollectionsPage');

  @override
  Future<LibraryPage<MediaItem>> fetchCollectionPage(
    String collectionId, {
    int? start,
    int? size,
    AbortController? abort,
    String? libraryId,
    String? libraryTitle,
  }) =>
      throw UnsupportedError('VIDYA: fetchCollectionPage');

  @override
  Future<String?> createCollection({
    required String libraryId,
    required String title,
    required List<MediaItem> items,
    MediaKind? itemKind,
  }) async =>
      null;

  @override
  Future<bool> addToCollection({required String collectionId, required List<MediaItem> items}) async => false;

  @override
  Future<bool> removeFromCollection({required String collectionId, required MediaItem item}) async => false;

  @override
  Future<bool> deleteCollection(MediaItem collection) async => false;

  @override
  Future<bool> deleteMediaItem(MediaItem item) async => false;

  @override
  Future<MediaFileInfo?> getFileInfo(MediaItem item) async => null;

  @override
  Future<ExternalIds> fetchExternalIds(String itemId) =>
      throw UnsupportedError('VIDYA: fetchExternalIds');

  @override
  Future<PlaybackExtras> fetchPlaybackExtras(
    String itemId, {
    String? introPattern,
    String? creditsPattern,
    bool forceChapterFallback = false,
    bool forceRefresh = false,
  }) =>
      throw UnsupportedError('VIDYA: fetchPlaybackExtras');

  @override
  Future<PlaybackExtras?> fetchPlaybackExtrasFromCacheOnly(
    String itemId, {
    String? introPattern,
    String? creditsPattern,
    bool forceChapterFallback = false,
  }) async =>
      null;

  @override
  Future<MediaSourceInfo?> fetchCachedMediaSourceInfo(String itemId) async => null;

  @override
  Future<ScrubPreviewSource?> createScrubPreviewSource({
    required MediaItem item,
    required MediaSourceInfo mediaSource,
  }) async =>
      null;

  @override
  double get watchedThreshold => 0.9;

  @override
  bool get marksWatchedOnPlaybackStopped => false;

  @override
  Future<void> reportPlaybackStarted({
    required String itemId,
    required Duration position,
    Duration? duration,
    String? playSessionId,
    String? playMethod,
    String? mediaSourceId,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
  }) async {}

  @override
  Future<void> reportPlaybackProgress({
    required String itemId,
    required Duration position,
    required Duration duration,
    bool isPaused = false,
    String? playSessionId,
    String? playMethod,
    String? mediaSourceId,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
  }) async {}

  @override
  Future<void> reportPlaybackStopped({
    required String itemId,
    required Duration position,
    Duration? duration,
    String? playSessionId,
    String? mediaSourceId,
    PlaybackReportMetadata report = const PlaybackReportMetadata.live(),
  }) async {}

  @override
  Future<PlaybackInitializationResult> getPlaybackInitialization(
    PlaybackInitializationOptions options,
  ) =>
      throw UnsupportedError('VIDYA items use their own player, not the shared video player');

  @override
  Future<DownloadResolution> resolveDownload(MediaItem item, {int mediaIndex = 0}) =>
      throw UnsupportedError('VIDYA: resolveDownload');

  @override
  List<DownloadArtworkSpec> resolveDownloadArtwork(MediaItem item) => [];

  @override
  Future<String?> resolveExternalPlaybackUrl(
    MediaItem item, {
    int mediaIndex = 0,
    String? mediaSourceId,
  }) async =>
      null;
}

/// Null live-TV stub for VIDYA servers (no live TV capability).
///
/// `noSuchMethod` satisfies the remaining ~40 abstract interface members
/// without requiring model imports for every DVR/EPG type — those code paths
/// are never reached because [isAvailable] returns false.
class _VidyaNullLiveTvSupport implements LiveTvSupport {
  @override
  Future<bool> isAvailable() async => false;

  @override
  Future<String> buildFavoriteChannelSource({String? lineup}) async => '';

  @override
  String get favoriteStoreKey => '';

  @override
  FavoriteChannelPersistenceMode get favoritePersistenceMode =>
      FavoriteChannelPersistenceMode.serverSlice;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Live TV is not supported on VIDYA servers');
}
