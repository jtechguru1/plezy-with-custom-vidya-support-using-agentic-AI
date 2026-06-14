/// Playback session context for a single VIDYA lecture. Distinct from
/// [VidyaAccountConnection] which is the persisted server credential.
class VidyaPlaybackSession {
  final String baseUrl;
  final String token;
  final String courseId;
  final String lectureId;

  const VidyaPlaybackSession({
    required this.baseUrl,
    required this.token,
    required this.courseId,
    required this.lectureId,
  });
}
