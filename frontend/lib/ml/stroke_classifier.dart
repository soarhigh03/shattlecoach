// On-device ST-GCN stroke classifier — used to SANITY-CHECK the user's manually
// selected stroke. It does NOT drive scoring; the user's choice always wins.
//
// Model: scorer_v3_robust_int8.onnx — domain-adapted (confidence-randomization
// retraining) + dynamic-INT8 quantized (308KB). ~80% on held-out phone clips
// vs ~28% for the original BST-only model.
//
// Preprocessing MUST match retrain_robust.py norm_clip(): confidence-gated
// hip/shoulder centering + scale, outlier clip to [-3,3], confidence KEPT,
// temporal resample to T=32.

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

import 'pose_extractor.dart' show kCocoNames;

const List<String> kStrokeClasses = <String>[
  'high_clear',
  'short_serve',
  'forehand_drive',
];
const int kTargetTime = 32;
const double kDefaultTemperature = 0.861;
// QDQ static INT8: mobile onnxruntime lacks the ConvInteger kernel that DYNAMIC
// INT8 emits, but QDQ static quantization uses QuantizeLinear/DequantizeLinear
// around plain Conv — which mobile onnxruntime DOES support. 327KB (3.2x smaller
// than FP32), 77.1% on held-out phone clips (vs 80.0% FP32). This is the shipped,
// quantized, mobile-compatible model.
const String kClassifierAsset = 'assets/scorer_v3_robust_qdq_int8.onnx';

final Map<String, int> _idx = <String, int>{
  for (int i = 0; i < kCocoNames.length; i++) kCocoNames[i]: i,
};

class StrokePrediction {
  final String label;
  final List<double> softmax;
  final double topConfidence;
  final int inferenceMs;
  StrokePrediction({
    required this.label,
    required this.softmax,
    required this.topConfidence,
    required this.inferenceMs,
  });
  Map<String, dynamic> toJson() => <String, dynamic>{
    'label': label,
    'softmax_3class': <String, double>{
      for (int i = 0; i < kStrokeClasses.length; i++)
        kStrokeClasses[i]: softmax[i],
    },
    'top_confidence': topConfidence,
    'scorer_ms': inferenceMs,
  };
}

class StrokeClassifier {
  StrokeClassifier._(this._session, this._inputName, this._temperature);
  final OrtSession _session;
  final String _inputName;
  final double _temperature;
  static StrokeClassifier? _instance;
  static bool _loadFailed = false;

  /// Diagnostic: last load/inference error (surfaced in UI for debugging).
  static String? lastError;

  static Future<StrokeClassifier?> tryLoad() async {
    if (_instance != null) return _instance;
    if (_loadFailed) return null;
    try {
      final OrtSession session = await OnnxRuntime().createSessionFromAsset(
        kClassifierAsset,
      );
      String inputName = 'skeleton';
      try {
        final List<String> names = session.inputNames;
        if (names.isNotEmpty && !names.contains(inputName)) {
          inputName = names.first;
        }
      } catch (_) {}
      double t = kDefaultTemperature;
      try {
        final Map<String, dynamic> tj =
            jsonDecode(await rootBundle.loadString('assets/temperature.json'))
                as Map<String, dynamic>;
        t = (tj['temperature'] as num).toDouble();
      } catch (_) {}
      _instance = StrokeClassifier._(session, inputName, t);
      return _instance;
    } catch (e) {
      _loadFailed = true;
      lastError = 'load: ${e.runtimeType}: $e';
      return null;
    }
  }

  Future<StrokePrediction> predict(List<List<List<double>>> kpts) async {
    final Stopwatch sw = Stopwatch()..start();
    final List<List<List<double>>> proc = _preprocess(kpts, kTargetTime);
    final Float32List flat = Float32List(1 * 3 * kTargetTime * 17);
    int wi = 0;
    for (int c = 0; c < 3; c++) {
      for (int t = 0; t < kTargetTime; t++) {
        for (int j = 0; j < 17; j++) {
          flat[wi++] = proc[t][j][c];
        }
      }
    }
    final OrtValue inp = await OrtValue.fromList(flat, <int>[
      1,
      3,
      kTargetTime,
      17,
    ]);
    Map<String, OrtValue>? outs;
    try {
      outs = await _session.run(<String, OrtValue>{_inputName: inp});
      final OrtValue logitsV = outs['stroke_logits'] ?? outs.values.first;
      final List<dynamic> nested = await logitsV.asList();
      final List<double> logits = (nested.first as List<dynamic>)
          .map<double>((dynamic e) => (e as num).toDouble())
          .toList();
      final List<double> scaled = logits
          .map<double>((double v) => v / _temperature)
          .toList();
      final double mx = scaled.reduce(math.max);
      final List<double> ex = scaled
          .map<double>((double v) => math.exp(v - mx))
          .toList();
      final double s = ex.reduce((double a, double b) => a + b);
      final List<double> probs = ex.map<double>((double e) => e / s).toList();
      int top = 0;
      for (int i = 1; i < probs.length; i++) {
        if (probs[i] > probs[top]) top = i;
      }
      sw.stop();
      return StrokePrediction(
        label: kStrokeClasses[top],
        softmax: probs,
        topConfidence: probs[top],
        inferenceMs: sw.elapsedMilliseconds,
      );
    } finally {
      try {
        await inp.dispose();
      } catch (_) {}
      if (outs != null) {
        for (final OrtValue v in outs.values) {
          try {
            await v.dispose();
          } catch (_) {}
        }
      }
    }
  }
}

// ----- preprocessing: mirrors retrain_robust.py norm_clip (eval path) -----

List<List<List<double>>> _preprocess(List<List<List<double>>> kpts, int tOut) {
  final int t = kpts.length;
  final List<List<List<double>>> out = List<List<List<double>>>.generate(
    t,
    (int i) => List<List<double>>.generate(
      17,
      (int j) => <double>[kpts[i][j][0], kpts[i][j][1], kpts[i][j][2]],
    ),
  );
  for (int i = 0; i < t; i++) {
    final List<double> conf = <double>[
      for (int j = 0; j < 17; j++) out[i][j][2],
    ];
    final List<double> mh = _gatedMean(
      out[i],
      conf,
      _idx['left_hip']!,
      _idx['right_hip']!,
    );
    final List<double> ms = _gatedMean(
      out[i],
      conf,
      _idx['left_shoulder']!,
      _idx['right_shoulder']!,
    );
    final double scale =
        math.sqrt(
          (ms[0] - mh[0]) * (ms[0] - mh[0]) + (ms[1] - mh[1]) * (ms[1] - mh[1]),
        ) +
        1e-6;
    for (int j = 0; j < 17; j++) {
      double x = (out[i][j][0] - mh[0]) / scale;
      double y = (out[i][j][1] - mh[1]) / scale;
      x = x < -3 ? -3 : (x > 3 ? 3 : x);
      y = y < -3 ? -3 : (y > 3 ? 3 : y);
      out[i][j][0] = x;
      out[i][j][1] = y;
    }
  }
  return _temporalResample(out, tOut);
}

List<double> _gatedMean(
  List<List<double>> frame,
  List<double> conf,
  int a,
  int b,
) {
  final List<int> use = <int>[];
  if (conf[a] > 0.2) use.add(a);
  if (conf[b] > 0.2) use.add(b);
  if (use.isEmpty) {
    use
      ..add(a)
      ..add(b);
  }
  double sx = 0, sy = 0;
  for (final int j in use) {
    sx += frame[j][0];
    sy += frame[j][1];
  }
  return <double>[sx / use.length, sy / use.length];
}

List<List<List<double>>> _temporalResample(
  List<List<List<double>>> kpts,
  int tOut,
) {
  final int tIn = kpts.length;
  if (tIn == tOut) return kpts;
  final List<List<List<double>>> out = List<List<List<double>>>.generate(
    tOut,
    (_) => List<List<double>>.generate(17, (_) => <double>[0, 0, 0]),
  );
  for (int j = 0; j < 17; j++) {
    for (int c = 0; c < 3; c++) {
      for (int o = 0; o < tOut; o++) {
        final double srcT = (tIn - 1) * (o / (tOut - 1));
        final int t0 = srcT.floor();
        final int t1 = math.min(t0 + 1, tIn - 1);
        final double frac = srcT - t0;
        out[o][j][c] = kpts[t0][j][c] * (1 - frac) + kpts[t1][j][c] * frac;
      }
    }
  }
  return out;
}
