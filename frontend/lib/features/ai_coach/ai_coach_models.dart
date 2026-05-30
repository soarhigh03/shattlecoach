import 'dart:io';

/// One AI coaching run. Persists in-memory for the session so the report
/// heatmap can read the same data the AI Coach screen wrote.
///
/// `outputVideo` and `feedback` are nullable to leave room for the algorithm
/// pipeline (not yet implemented) — a freshly created entry only has the input
/// clip filled in.
class AiCoachAnalysis {
  AiCoachAnalysis({
    required this.id,
    required this.createdAt,
    required this.inputVideo,
    this.outputVideo,
    this.feedback,
  });

  final String id;
  final DateTime createdAt;
  final File inputVideo;
  final File? outputVideo;
  final String? feedback;

  /// Calendar-bucket key (year/month/day at midnight) used by the heatmap.
  DateTime get day =>
      DateTime(createdAt.year, createdAt.month, createdAt.day);

  AiCoachAnalysis copyWith({File? outputVideo, String? feedback}) {
    return AiCoachAnalysis(
      id: id,
      createdAt: createdAt,
      inputVideo: inputVideo,
      outputVideo: outputVideo ?? this.outputVideo,
      feedback: feedback ?? this.feedback,
    );
  }
}
