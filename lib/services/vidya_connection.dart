/// Playback session context for a single VIDYA lecture. Distinct from
/// [VidyaAccountConnection] which is the persisted server credential.
class VidyaPlaybackSession {
  final String baseUrl;
  final String token;
  final String courseId;
  final String lectureId;

  /// Seconds into the lecture to seek on first load. Zero or null means start
  /// from the beginning (new lecture or no saved position).
  final int resumePositionSeconds;

  const VidyaPlaybackSession({
    required this.baseUrl,
    required this.token,
    required this.courseId,
    required this.lectureId,
    this.resumePositionSeconds = 0,
  });
}
