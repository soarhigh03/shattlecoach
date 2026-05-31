// ShattleCoach on-device ML — one-call facade for app integration.
//
// The whole pipeline behind a single call:
//   final score = await ShattleMl.analyzeSwing(videoPath: path, stroke: 'high_clear');
// No server, no network, no API key. Stroke is the USER's choice (the classifier
// is intentionally not used). See backend/ONDEVICE_INTEGRATION.md.

import 'axis_filter.dart';
import 'impact_annotator.dart';
import 'llm_client.dart';
import 'pose_extractor.dart';
import 'rule_calibration.dart';
import 'rule_scorer.dart';
import 'rulebook_tips.dart';
import 'speed_step_scorer.dart';

/// The three strokes the user can pick. Pass one of these to [ShattleMl.analyzeSwing].
const List<String> kShattleStrokes = <String>[
  'high_clear',
  'short_serve',
  'forehand_drive',
];

/// Structured result of one swing analysis. `status == 'OK'` means valid; otherwise
/// the clip was rejected (see [messageKo]).
class ShattleScore {
  final String status; // 'OK' | 'REJECTED_LOW_POSE_DETECTION'
  final String? messageKo; // user-facing reason when rejected
  final String stroke; // the stroke that was analysed
  final List<String>
  axesEvaluated; // which of posture/speed/step apply to this stroke
  final int? postureStars; // 1-5 (null if unmeasurable)
  final int? speedStars; // present only if 'speed' in axesEvaluated
  final int? stepStars; // present only if 'step' in axesEvaluated
  final List<String> positives; // "doing well" lines (✓)
  final String coachingParagraph; // the coaching text to show
  final String
  coachingSource; // 'rulebook' (deterministic) | 'llm' (Groq-smoothed)
  final String?
  annotatedImpactPngBase64; // impact frame with markers (base64 PNG) or null
  final String? annotationSkipReason; // why the image is null, if so
  final double processingSeconds;
  final Map<String, dynamic> raw; // full payload for advanced/debug use

  ShattleScore({
    required this.status,
    this.messageKo,
    required this.stroke,
    required this.axesEvaluated,
    this.postureStars,
    this.speedStars,
    this.stepStars,
    required this.positives,
    required this.coachingParagraph,
    this.coachingSource = 'rulebook',
    this.annotatedImpactPngBase64,
    this.annotationSkipReason,
    required this.processingSeconds,
    required this.raw,
  });

  bool get isOk => status == 'OK';
}

class ShattleMl {
  ShattleMl._();

  static BstPercentiles? _percentiles;
  static AxisFilter? _filter;
  static RuleCalibration? _calib;
  static RulebookTips? _bank;

  /// Loads the bundled assets once (idempotent). Safe to call before the first
  /// analysis to warm up, or just let [analyzeSwing] call it lazily.
  static Future<void> warmUp() async {
    _filter ??= await AxisFilter.load();
    _percentiles ??= await BstPercentiles.load();
    _calib ??= await RuleCalibration.load();
    _bank ??= await RulebookTips.load();
  }

  /// Analyse [videoPath] for the user-selected [stroke] (one of [kShattleStrokes]).
  /// [onStatus] receives short progress strings. Throws on pipeline failure.
  static Future<ShattleScore> analyzeSwing({
    required String videoPath,
    required String stroke,
    double fps = 15.0,
    bool enableLlm = true,
    int? startMs,
    int? endMs,
    void Function(String status)? onStatus,
  }) async {
    assert(
      kShattleStrokes.contains(stroke),
      'stroke must be one of $kShattleStrokes',
    );
    await warmUp();

    onStatus?.call('자세 추출 중…');
    final Stopwatch sw = Stopwatch()..start();
    final ExtractionResult ext = await extractPose(
      videoPath,
      fps: fps,
      startMs: startMs,
      endMs: endMs,
      onProgress: (int done, int total) {
        if (done % 4 == 0) onStatus?.call('자세 추출: $done / $total 프레임');
      },
    );
    if (ext.detectionRate < 0.5) {
      sw.stop();
      final String msg =
          '영상에서 사람을 잘 인식하지 못했어요 (${(ext.detectionRate * 100).toStringAsFixed(0)}%). '
          '옆에서 전신이 한 화면에 나오게 다시 촬영해 주세요.';
      return ShattleScore(
        status: 'REJECTED_LOW_POSE_DETECTION',
        messageKo: msg,
        stroke: stroke,
        axesEvaluated: const <String>[],
        positives: const <String>[],
        coachingParagraph: '',
        processingSeconds: sw.elapsedMilliseconds / 1000.0,
        raw: <String, dynamic>{
          'status': 'REJECTED_LOW_POSE_DETECTION',
          'message_ko': msg,
        },
      );
    }

    onStatus?.call('폼 채점 중…');
    final List<List<List<double>>> kpts = ext.frames
        .map((PoseFrame f) => f.keypoints)
        .toList();

    final RuleScoreResult rule = scoreRules(kpts, smoothWindow: 5);
    String calibSource = 'synth';
    final List<CriterionResult> criteria = _calib!.apply(
      rule.criteria,
      stroke,
      outSource: (String s) => calibSource = s,
    );
    final List<double> validProbs = criteria
        .where((CriterionResult c) => c.measurement != null)
        .map((CriterionResult c) => c.probability)
        .toList();
    final int? postureStars = validProbs.isEmpty
        ? null
        : (1 +
                  (4 *
                      (validProbs.reduce((double a, double b) => a + b) /
                          validProbs.length)))
              .round();
    final AxisScoreResult speed = scoreSpeed(kpts, _percentiles!.speed);
    final AxisScoreResult step = scoreStep(kpts, _percentiles!.step);

    final Map<String, dynamic> payload = <String, dynamic>{
      'version': 'v9-offline',
      'status': 'OK',
      'mode': 'offline',
      'stroke': <String, dynamic>{'label': stroke, 'source': 'user_selected'},
      'posture_stars': postureStars,
      'posture_threshold_source': calibSource,
      'speed_stars': speed.star,
      'step_stars': step.star,
      'posture_criteria': criteria
          .map((CriterionResult c) => c.toJson())
          .toList(),
      'speed_details': speed.details,
      'step_details': step.details,
      'pose_detection_rate': ext.detectionRate,
      'pose_extraction_seconds': ext.extractSeconds,
    };
    _filter!.apply(
      payload,
    ); // keys off the selected stroke; drops irrelevant axes' keys

    onStatus?.call('임팩트 자세 주석…');
    try {
      final AnnotationResult ann = await annotateImpactOffline(
        videoPath: videoPath,
        kpts: kpts,
        postureCriteria: (payload['posture_criteria'] as List<dynamic>)
            .map((dynamic c) => c as Map<String, dynamic>)
            .toList(),
        detectionRate: ext.detectionRate,
        strokeLabel: stroke,
        fps: fps,
        startMs: startMs ?? 0,
      );
      payload['annotated_impact_png_base64'] = ann.pngBase64;
      payload['best_frame_index'] = ann.frameIndex;
      payload['annotation_skip_reason'] = ann.skipReason;
    } catch (e) {
      payload['annotated_impact_png_base64'] = null;
      payload['annotation_skip_reason'] = 'annotation error: $e';
    }

    onStatus?.call('코칭 생성…');
    int seed = rule.impactFrame + speed.star * 7 + step.star * 13;
    for (final CriterionResult c in criteria) {
      if (c.measurement != null) seed += (c.measurement! * 100).round();
    }
    final Map<String, dynamic> rb = composeCoaching(
      _bank!,
      payload,
      seed: seed.abs(),
    );

    // LLM smoothing (optional): stitch the deterministic rulebook sentences into
    // one natural paragraph. Guardrailed — the smoothed text is discarded if it
    // introduces a forbidden keyword. Any failure (no build-time key / offline /
    // timeout / bad response) silently keeps the deterministic rulebook fallback,
    // so coaching always works even with no network.
    if (enableLlm && GroqCoach.hasKey) {
      onStatus?.call('코칭 다듬는 중…');
      final List<String> sentenceTexts =
          ((rb['sentences'] as List<dynamic>?) ?? const <dynamic>[])
              .map(
                (dynamic e) =>
                    (e as Map<String, dynamic>)['text']?.toString() ?? '',
              )
              .where((String t) => t.isNotEmpty)
              .toList();
      final String fallback = (rb['paragraph'] as String?) ?? '';
      final List<String> forbidden = _bank!.forbiddenKeywords(stroke);
      // Only ask the model to avoid forbidden tokens not already (correctly) used.
      final List<String> promptForbidden = forbidden
          .where(
            (String k) => !fallback.toLowerCase().contains(k.toLowerCase()),
          )
          .toList();
      final LlmResult llm = await GroqCoach.smooth(
        sentenceTexts: sentenceTexts,
        forbidden: promptForbidden,
      );
      final String? smoothed = llm.paragraph;
      if (smoothed != null) {
        final List<String> introduced = RulebookTips.introducedForbidden(
          smoothed,
          fallback,
          forbidden,
        );
        if (introduced.isEmpty) {
          rb['paragraph'] = smoothed;
          rb['source'] = 'llm';
          rb['llm'] = llm.toJson();
        } else {
          rb['llm'] = LlmResult.skip(
            "smoothed output introduced forbidden keyword '${introduced.first}'; used fallback",
          ).toJson();
        }
      } else {
        rb['llm'] = llm.toJson();
      }
    }
    payload['rulebook'] = rb;

    sw.stop();
    payload['processing_seconds'] = sw.elapsedMilliseconds / 1000.0;

    final List<String> axes =
        ((payload['axes_evaluated'] as List<dynamic>?) ?? const <dynamic>[])
            .map((dynamic e) => e.toString())
            .toList();
    final List<String> positives =
        ((rb['positives'] as List<dynamic>?) ?? const <dynamic>[])
            .map(
              (dynamic e) =>
                  (e as Map<String, dynamic>)['text']?.toString() ?? '',
            )
            .where((String t) => t.isNotEmpty)
            .toList();
    return ShattleScore(
      status: 'OK',
      stroke: stroke,
      axesEvaluated: axes,
      postureStars: payload['posture_stars'] as int?,
      speedStars: payload['speed_stars'] as int?,
      stepStars: payload['step_stars'] as int?,
      positives: positives,
      coachingParagraph: (rb['paragraph'] as String?) ?? '',
      coachingSource: (rb['source'] as String?) ?? 'rulebook',
      annotatedImpactPngBase64:
          payload['annotated_impact_png_base64'] as String?,
      annotationSkipReason: payload['annotation_skip_reason'] as String?,
      processingSeconds: payload['processing_seconds'] as double,
      raw: payload,
    );
  }
}
