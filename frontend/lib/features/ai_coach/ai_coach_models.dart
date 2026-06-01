import 'dart:io';
import 'dart:typed_data';

/// Korean display labels for the strokes the on-device ML accepts.
/// Keys match `kShattleStrokes` in `lib/ml/shattle_ml.dart`.
const Map<String, String> kStrokeLabelKo = <String, String>{
  'high_clear': '하이클리어',
  'short_serve': '숏서브',
  'forehand_drive': '포핸드 드라이브',
};

/// One AI coaching run. Persists in-memory for the session so the report
/// heatmap can read the same data the AI coach screen wrote.
///
/// Star fields are nullable because the ML side evaluates only the axes
/// that apply to the selected stroke (e.g. serve has no swing-speed score).
class AiCoachAnalysis {
  AiCoachAnalysis({
    required this.id,
    required this.createdAt,
    required this.inputVideo,
    required this.stroke,
    required this.coachingParagraph,
    this.positives = const <String>[],
    this.postureStars,
    this.speedStars,
    this.stepStars,
    this.impactImage,
    this.predictedStroke,
    this.predictedConfidence,
    this.strokeMismatch = false,
  });

  final String id;
  final DateTime createdAt;
  final File inputVideo;
  final String stroke;
  final List<String> positives;
  final String coachingParagraph;
  final int? postureStars;
  final int? speedStars;
  final int? stepStars;

  /// Decoded PNG of the impact frame with rule-based annotations drawn over
  /// it. Null when the ML pipeline could not produce one (low detection rate,
  /// decode failure, etc.).
  final Uint8List? impactImage;

  /// Stroke-confirmation classifier output (best-effort). [strokeMismatch] is
  /// true when the classifier confidently disagrees with the user's pick; the
  /// UI then offers a re-analysis. Null/false when the check was skipped.
  final String? predictedStroke;
  final double? predictedConfidence;
  final bool strokeMismatch;

  /// Calendar-bucket key (year/month/day at midnight) used by the heatmap.
  DateTime get day => DateTime(createdAt.year, createdAt.month, createdAt.day);

  /// Mean of the non-null star scores. Used by the compact report card.
  /// Null when no axis was scored.
  double? get averageStars {
    final List<int> scored = <int?>[
      postureStars,
      speedStars,
      stepStars,
    ].whereType<int>().toList();
    if (scored.isEmpty) return null;
    return scored.fold<int>(0, (int a, int b) => a + b) / scored.length;
  }

  String get strokeLabelKo => kStrokeLabelKo[stroke] ?? stroke;
}
