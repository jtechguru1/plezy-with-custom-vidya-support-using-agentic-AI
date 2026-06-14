class VidyaConnection {
  final String baseUrl;
  final String token;
  final String courseId;
  final String lectureId;

  const VidyaConnection({
    required this.baseUrl,
    required this.token,
    required this.courseId,
    required this.lectureId,
  });
}
