// Offline impact-frame annotation (D2 / D4 / D5 — review round 1).
//
// Dart twin of scripts/annotate_frame.py for the on-device path. The PC-server
// path drew red circles + yellow arrows + Korean labels on the impact frame and
// embedded it as base64 PNG; the offline path produced none, so the app's
// _annotatedImpactCard silently vanished. This re-creates that visualization:
//   1. locate the impact frame (D4: smoothed wrist-velocity global max, edges trimmed),
//   2. re-fetch that frame's JPEG via the native channel,
//   3. draw markers/arrows/labels with dart:ui Canvas (Korean needs the system
//      font — the `image` package has no CJK glyphs), scaled to the player bbox (D5),
//   4. encode PNG → base64.
//
// Korean labels are intentionally generic per failed criterion (matching the
// Python COACHING semantics). Which criteria fail is already gated by the
// user-selected stroke's per-class thresholds, so serve/drive don't get
// overhead-clear advice.

import 'dart:convert' show base64Encode;
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import 'pose_extractor.dart' show fetchFrameJpegAtIndex, kCocoNames;
import 'rule_scorer.dart' show edgeTrim;

final Map<String, int> _idx = <String, int>{
  for (int i = 0; i < kCocoNames.length; i++) kCocoNames[i]: i,
};

class AnnotationResult {
  final String? pngBase64;
  final int frameIndex;
  final String? skipReason;
  AnnotationResult(this.pngBase64, this.frameIndex, this.skipReason);
}

class _Correction {
  final String joint;
  final double dx;
  final double dy;
  final String label;
  _Correction(this.joint, this.dx, this.dy, this.label);
}

/// D4: impact = global max of the smoothed dominant-wrist speed, within the
/// edge-trimmed range. Mirrors annotate_frame.find_impact_frame.
int _impactFrame(List<List<List<double>>> kpts, int wristIdx) {
  final int t = kpts.length;
  if (t < 2) return 0;
  final List<double> sp = <double>[];
  for (int i = 1; i < t; i++) {
    final double dx = kpts[i][wristIdx][0] - kpts[i - 1][wristIdx][0];
    final double dy = kpts[i][wristIdx][1] - kpts[i - 1][wristIdx][1];
    sp.add(math.sqrt(dx * dx + dy * dy));
  }
  List<double> sm = sp;
  if (sp.length >= 3) {
    sm = List<double>.generate(sp.length, (int i) {
      final double a = i > 0 ? sp[i - 1] : 0.0;
      final double b = sp[i];
      final double c = i < sp.length - 1 ? sp[i + 1] : 0.0;
      return (a + b + c) / 3.0;
    });
  }
  final List<int> r = edgeTrim(sm.length);
  final int lo = r[0], hi = r[1];
  double best = -1;
  int bestI = lo;
  for (int i = lo; i < hi; i++) {
    if (sm[i] > best) { best = sm[i]; bestI = i; }
  }
  return bestI;
}

int _dominantWristIdx(List<List<List<double>>> kpts) {
  double lc = 0, rc = 0;
  final int li = _idx['left_wrist']!, ri = _idx['right_wrist']!;
  for (final List<List<double>> f in kpts) { lc += f[li][2]; rc += f[ri][2]; }
  return rc >= lc ? ri : li;
}

// Stroke-aware corrections. The arrow DIRECTION + LABEL only make sense per
// stroke (e.g. "raise the wrist" is right for an overhead clear but ILLEGAL for
// a serve), so each criterion maps differently by stroke. For strokes where a
// criterion has no single correct direction we draw only the circle (no arrow)
// with a short, stroke-correct cue — never a misleading one.
List<_Correction> _corrections(
    List<Map<String, dynamic>> failed, List<List<double>> kptsAtImpact, int wristIdx, String stroke) {
  final List<_Correction> out = <_Correction>[];
  final bool right = wristIdx == _idx['right_wrist'];
  for (final Map<String, dynamic> c in failed) {
    final String name = (c['name'] as String?) ?? '';
    if (c['measurement'] == null || c['threshold'] == null) continue;
    switch (name) {
      case 'peak_wrist_above_shoulder':
        if (stroke == 'high_clear') {
          out.add(_Correction(kCocoNames[wristIdx], 0, -110, '타점 더 높이 ↑'));
        } else if (stroke == 'forehand_drive') {
          out.add(_Correction(kCocoNames[wristIdx], 0, 0, '몸 앞 어깨높이'));
        } else { // short_serve / unknown — never tell them to raise (illegal)
          out.add(_Correction(kCocoNames[wristIdx], 0, 0, '타점 낮게 유지'));
        }
        break;
      case 'elbow_extension_>=160deg':
        final int elbow = _idx[right ? 'right_elbow' : 'left_elbow']!;
        if (stroke == 'high_clear') {
          final double vx = kptsAtImpact[wristIdx][0] - kptsAtImpact[elbow][0];
          final double vy = kptsAtImpact[wristIdx][1] - kptsAtImpact[elbow][1];
          final double n = math.sqrt(vx * vx + vy * vy) + 1e-6;
          out.add(_Correction(kCocoNames[elbow], vx / n * 100, vy / n * 100, '팔꿈치 펴기'));
        } else if (stroke == 'forehand_drive') {
          out.add(_Correction(kCocoNames[elbow], 0, 0, '전완 회내'));
        } else {
          out.add(_Correction(kCocoNames[elbow], 0, 0, '팔 편하게'));
        }
        break;
      case 'hip_rotation_>=20deg':
        if (stroke == 'short_serve') {
          out.add(_Correction('right_hip', 0, 0, '상체 고정'));
        } else {
          out.add(_Correction('right_hip', 80, 0, '허리 회전 더 →'));
        }
        break;
      case 'knees_bent_at_prep':
        out.add(_Correction('right_knee', 0, 85, stroke == 'short_serve' ? '무릎 살짝 ↓' : '무릎 굽히기 ↓'));
        out.add(_Correction('left_knee', 0, 85, ''));
        break;
    }
  }
  return out;
}

double _playerScale(List<List<double>> kpts, double imgH) {
  final List<double> ys = <double>[
    for (final List<double> j in kpts) if (j[2] > 0.2) j[1]
  ];
  final double bboxH = ys.length >= 2
      ? (ys.reduce(math.max) - ys.reduce(math.min))
      : imgH * 0.5;
  return (bboxH / 420.0).clamp(0.55, 2.4);
}

/// End-to-end offline annotation. Returns base64 PNG (+ frame index) or a
/// skip reason explaining why it's empty (D2: never fail silently).
Future<AnnotationResult> annotateImpactOffline({
  required String videoPath,
  required List<List<List<double>>> kpts,
  required List<Map<String, dynamic>> postureCriteria,
  required double detectionRate,
  String strokeLabel = '',
  double fps = 15.0,
}) async {
  if (detectionRate < 0.5) {
    return AnnotationResult(null, -1,
        'pose detection ${(detectionRate * 100).toStringAsFixed(0)}% — frame too noisy to annotate');
  }
  if (kpts.length < 2) {
    return AnnotationResult(null, -1, 'too few frames to locate impact');
  }
  final List<Map<String, dynamic>> failed = postureCriteria
      .where((Map<String, dynamic> c) => c['pass'] == false && c['measurement'] != null)
      .toList();
  final int wristIdx = _dominantWristIdx(kpts);
  final int frameIdx = _impactFrame(kpts, wristIdx);

  final Uint8List? jpeg = await fetchFrameJpegAtIndex(videoPath, frameIdx, fps: fps);
  if (jpeg == null || jpeg.length < 100) {
    return AnnotationResult(null, frameIdx, 'could not re-read impact frame $frameIdx');
  }

  ui.Image image;
  try {
    final ui.Codec codec = await ui.instantiateImageCodec(jpeg);
    image = (await codec.getNextFrame()).image;
  } catch (e) {
    return AnnotationResult(null, frameIdx, 'frame decode failed: $e');
  }

  final List<_Correction> corrections = _corrections(failed, kpts[frameIdx], wristIdx, strokeLabel);
  const Map<String, String> ko = <String, String>{
    'high_clear': '하이클리어', 'short_serve': '숏서브', 'forehand_drive': '포핸드 드라이브',
  };
  try {
    final Uint8List png = await _draw(image, kpts[frameIdx], corrections, ko[strokeLabel] ?? '');
    return AnnotationResult(base64Encode(png), frameIdx, null);
  } catch (e) {
    image.dispose();
    return AnnotationResult(null, frameIdx, 'draw failed: $e');
  }
}

Future<Uint8List> _draw(ui.Image image, List<List<double>> kpts,
    List<_Correction> corrections, String strokeLabel) async {
  final double w = image.width.toDouble(), h = image.height.toDouble();
  final ui.PictureRecorder rec = ui.PictureRecorder();
  final Canvas canvas = Canvas(rec, Rect.fromLTWH(0, 0, w, h));
  canvas.drawImage(image, Offset.zero, Paint());

  final double s = _playerScale(kpts, h);
  final double r = math.max(10, 28 * s);
  final double lw = math.max(3, 7 * s);
  final double fontSize = math.max(15, 26 * s);
  final Paint ring = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = math.max(3, 5 * s)
    ..color = const Color(0xFFE62828);
  final Paint arrow = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = lw
    ..strokeCap = StrokeCap.round
    ..color = const Color(0xFFFFC800);

  for (final _Correction c in corrections) {
    final int? ji = _idx[c.joint];
    if (ji == null) continue;
    final double x = kpts[ji][0], y = kpts[ji][1], conf = kpts[ji][2];
    if (conf < 0.2) continue;
    final Offset p = Offset(x, y);
    canvas.drawCircle(p, r, ring);
    final double dx = c.dx * s, dy = c.dy * s;
    if (dx != 0 || dy != 0) {
      final Offset e = Offset(x + dx, y + dy);
      canvas.drawLine(p, e, arrow);
      final double ang = math.atan2(dy, dx);
      final double ah = math.max(10, 22 * s);
      for (final double off in <double>[-0.4, 0.4]) {
        canvas.drawLine(e,
            Offset(e.dx - ah * math.cos(ang + off), e.dy - ah * math.sin(ang + off)), arrow);
      }
    }
    if (c.label.isNotEmpty) {
      _label(canvas, c.label, x, y + r + 8 * s, w, h, fontSize);
    }
  }

  // title bar
  canvas.drawRect(Rect.fromLTWH(0, 0, w, 50), Paint()..color = const Color(0xFFB41E1E));
  _text(canvas, strokeLabel.isEmpty ? '임팩트 자세 — 빨간 부분 수정' : '임팩트 자세 — 빨간 부분 수정  ($strokeLabel)',
      const Offset(16, 9), const Color(0xFFFFFFFF), 22);

  final ui.Picture pic = rec.endRecording();
  final ui.Image out = await pic.toImage(image.width, image.height);
  image.dispose();
  final ByteData? bd = await out.toByteData(format: ui.ImageByteFormat.png);
  out.dispose();
  if (bd == null) throw StateError('toByteData(png) returned null');
  return bd.buffer.asUint8List();
}



TextPainter _tp(String text, Color color, double size) {
  final TextPainter tp = TextPainter(
    text: TextSpan(text: text, style: TextStyle(color: color, fontSize: size, fontWeight: FontWeight.w700)),
    textDirection: TextDirection.ltr,
  );
  tp.layout();
  return tp;
}

void _text(Canvas canvas, String text, Offset at, Color color, double size) {
  _tp(text, color, size).paint(canvas, at);
}

// D5: label with solid dark background box for contrast on busy court backgrounds.
void _label(Canvas canvas, String text, double cx, double cy, double w, double h, double size) {
  final TextPainter tp = _tp(text, const Color(0xFFFF5A50), size);
  final double tx = (cx - tp.width / 2).clamp(8.0, math.max(8.0, w - tp.width - 8));
  final double ty = math.min(h - tp.height - 12, cy);
  canvas.drawRRect(
    RRect.fromRectAndRadius(
      Rect.fromLTWH(tx - 6, ty - 4, tp.width + 12, tp.height + 8), const Radius.circular(4)),
    Paint()..color = const Color(0xE6141414),
  );
  tp.paint(canvas, Offset(tx, ty));
}
