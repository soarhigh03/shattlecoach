// On-device pose extraction: video → frames (native MediaMetadataRetriever via
// platform channel) → MoveNet TFLite → 17-COCO keypoints.
//
// Uses a native Kotlin MethodChannel for ms-precision frame extraction. This
// replaces video_compress (which capped at 1 fps via integer-second positions)
// and ML Kit pose (which needs Play Services pose module — missing on Galaxy S21).
//
// MoveNet Lightning Int8: 2.8 MB bundled in assets, 17 COCO keypoints output.

import 'dart:async';
import 'dart:isolate';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

// Multi-isolate MoveNet worker pool — each worker loads its own Interpreter
// (TFLite isn't thread-safe across isolates). 3 workers ≈ 3× throughput.
// Memory cost: ~50MB per Interpreter × 3 = ~150MB extra. Galaxy S21 (8GB) OK.

const List<String> kCocoNames = <String>[
  'nose',
  'left_eye',
  'right_eye',
  'left_ear',
  'right_ear',
  'left_shoulder',
  'right_shoulder',
  'left_elbow',
  'right_elbow',
  'left_wrist',
  'right_wrist',
  'left_hip',
  'right_hip',
  'left_knee',
  'right_knee',
  'left_ankle',
  'right_ankle',
];

const int _kInputSize = 192; // MoveNet Lightning input is 192x192
const MethodChannel _frameCh = MethodChannel(
  'com.shattlecoach/frame_extractor',
);

class PoseFrame {
  final int frameIndex;
  final int width;
  final int height;
  final List<List<double>> keypoints;
  PoseFrame({
    required this.frameIndex,
    required this.width,
    required this.height,
    required this.keypoints,
  });
  factory PoseFrame.empty(int idx, int w, int h) {
    return PoseFrame(
      frameIndex: idx,
      width: w,
      height: h,
      keypoints: List<List<double>>.generate(17, (_) => <double>[0, 0, 0]),
    );
  }
}

class ExtractionResult {
  final List<PoseFrame> frames;
  final int width;
  final int height;
  final double detectionRate;
  final double extractSeconds;
  ExtractionResult({
    required this.frames,
    required this.width,
    required this.height,
    required this.detectionRate,
    required this.extractSeconds,
  });
}

// =============== Worker pool ===============

// Worker now takes raw JPEG bytes and does decode + resize + inference inside
// the worker isolate. This eliminates Isolate.run from the main flow (which
// was crashing with "object is unsendable" due to closure capture).
class _WorkerJob {
  final int frameIndex;
  final Uint8List jpegBytes;
  final SendPort replyTo;
  _WorkerJob(this.frameIndex, this.jpegBytes, this.replyTo);
}

class _WorkerResult {
  final int frameIndex;
  final int origW;
  final int origH;
  final List<List<double>> keypoints;
  final String? error;
  _WorkerResult(
    this.frameIndex,
    this.origW,
    this.origH,
    this.keypoints,
    this.error,
  );
}

void _moveNetWorkerEntry(_WorkerInit init) async {
  final ReceivePort recv = ReceivePort();
  init.handshake.send(recv.sendPort);
  Interpreter? interp;
  try {
    interp = Interpreter.fromBuffer(init.modelBytes);
  } catch (e) {
    // Workers without a usable interpreter still drain the queue with errors.
  }
  await for (final dynamic msg in recv) {
    if (msg is _WorkerJob) {
      try {
        if (interp == null) {
          msg.replyTo.send(
            _WorkerResult(msg.frameIndex, 0, 0, _emptyKp(), 'interpreter null'),
          );
          continue;
        }
        // 1. Decode JPEG
        final img.Image? decoded = img.decodeJpg(msg.jpegBytes);
        if (decoded == null) {
          msg.replyTo.send(
            _WorkerResult(
              msg.frameIndex,
              0,
              0,
              _emptyKp(),
              'JPEG decode failed (size=${msg.jpegBytes.length})',
            ),
          );
          continue;
        }
        final int origW = decoded.width, origH = decoded.height;
        // 2. Resize to 192x192
        final img.Image resized = img.copyResize(
          decoded,
          width: _kInputSize,
          height: _kInputSize,
        );
        final Uint8List buf = Uint8List(_kInputSize * _kInputSize * 3);
        int wi = 0;
        for (int y = 0; y < _kInputSize; y++) {
          for (int x = 0; x < _kInputSize; x++) {
            final img.Pixel p = resized.getPixel(x, y);
            buf[wi++] = p.r.toInt();
            buf[wi++] = p.g.toInt();
            buf[wi++] = p.b.toInt();
          }
        }
        // 3. MoveNet inference
        final input = buf.buffer.asUint8List().reshape(<int>[
          1,
          _kInputSize,
          _kInputSize,
          3,
        ]);
        final output = List<List<List<List<double>>>>.generate(
          1,
          (_) => List<List<List<double>>>.generate(
            1,
            (_) => List<List<double>>.generate(
              17,
              (_) => List<double>.filled(3, 0),
            ),
          ),
        );
        interp.run(input, output);
        final List<List<double>> kp = List<List<double>>.generate(
          17,
          (_) => <double>[0, 0, 0],
        );
        for (int j = 0; j < 17; j++) {
          final double yNorm = output[0][0][j][0];
          final double xNorm = output[0][0][j][1];
          final double conf = output[0][0][j][2];
          kp[j] = <double>[xNorm * origW, yNorm * origH, conf];
        }
        msg.replyTo.send(_WorkerResult(msg.frameIndex, origW, origH, kp, null));
      } catch (e) {
        msg.replyTo.send(
          _WorkerResult(msg.frameIndex, 0, 0, _emptyKp(), e.toString()),
        );
      }
    } else if (msg == 'close') {
      try {
        interp?.close();
      } catch (_) {}
      recv.close();
      break;
    }
  }
}

class _WorkerInit {
  final Uint8List modelBytes;
  final SendPort handshake;
  _WorkerInit(this.modelBytes, this.handshake);
}

List<List<double>> _emptyKp() =>
    List<List<double>>.generate(17, (_) => <double>[0, 0, 0]);

class _WorkerPool {
  final List<SendPort> _ports;
  final List<Isolate> _isolates;
  int _rr = 0;
  _WorkerPool._(this._ports, this._isolates);

  static Future<_WorkerPool> spawn(int n) async {
    final ByteData modelData = await rootBundle.load(
      'assets/movenet_lightning_int8.tflite',
    );
    final Uint8List modelBytes = modelData.buffer.asUint8List();
    final List<SendPort> ports = <SendPort>[];
    final List<Isolate> isolates = <Isolate>[];
    for (int i = 0; i < n; i++) {
      final ReceivePort handshake = ReceivePort();
      final Isolate iso = await Isolate.spawn<_WorkerInit>(
        _moveNetWorkerEntry,
        _WorkerInit(modelBytes, handshake.sendPort),
      );
      final SendPort wp = await handshake.first as SendPort;
      ports.add(wp);
      isolates.add(iso);
    }
    return _WorkerPool._(ports, isolates);
  }

  Future<_WorkerResult> submit(int frameIndex, Uint8List jpegBytes) {
    final ReceivePort reply = ReceivePort();
    final SendPort target = _ports[_rr++ % _ports.length];
    target.send(_WorkerJob(frameIndex, jpegBytes, reply.sendPort));
    return reply.first.then((dynamic v) {
      reply.close();
      return v as _WorkerResult;
    });
  }

  void close() {
    for (final SendPort p in _ports) {
      try {
        p.send('close');
      } catch (_) {}
    }
    for (final Isolate i in _isolates) {
      try {
        i.kill(priority: Isolate.beforeNextEvent);
      } catch (_) {}
    }
  }
}

_WorkerPool? _sharedPool;
Future<_WorkerPool> _getPool() async {
  _sharedPool ??= await _WorkerPool.spawn(3);
  return _sharedPool!;
}

Future<int> _videoDurationMs(String path) async {
  try {
    final dynamic d = await _frameCh.invokeMethod<dynamic>(
      'getDurationMs',
      <String, dynamic>{'path': path},
    );
    return (d as num?)?.toInt() ?? 0;
  } catch (e) {
    throw Exception('native getDurationMs failed: $e');
  }
}

/// Public: re-fetch a single frame's JPEG by FRAME INDEX (same indexing
/// extractPose uses: timeMs = startMs + index * round(1000/fps)). Used by
/// the offline annotator (D2) to draw on the impact frame. Returns null on
/// failure.
///
/// [startMs] must match the value passed to [extractPose] so the index→time
/// mapping lines up — otherwise the annotator would redraw the wrong frame
/// when the caller analysed a trimmed range.
Future<Uint8List?> fetchFrameJpegAtIndex(
  String path,
  int frameIndex, {
  double fps = 15.0,
  int quality = 90,
  int startMs = 0,
}) async {
  final int frameStepMs = (1000.0 / fps).round();
  try {
    return await _getFrameJpeg(
      path,
      startMs + frameIndex * frameStepMs,
      quality: quality,
    );
  } catch (_) {
    return null;
  }
}

Future<Uint8List?> _getFrameJpeg(
  String path,
  int timeMs, {
  int quality = 85,
}) async {
  try {
    final Uint8List? bytes = await _frameCh.invokeMethod<Uint8List>(
      'getFrame',
      <String, dynamic>{'path': path, 'timeMs': timeMs, 'jpegQuality': quality},
    );
    return bytes;
  } on PlatformException catch (e) {
    throw Exception('native getFrame@${timeMs}ms: ${e.code} ${e.message}');
  }
}

/// Extracts pose from [videoPath] using a 3-isolate MoveNet worker pool.
/// Pipeline: native frame fetch → isolate preproc → worker pool MoveNet.
/// All 3 stages overlap; total throughput limited by slowest stage.
///
/// When [startMs] / [endMs] are passed, only frames inside that window are
/// sampled (used to honour the trim selection from the AI coach screen).
/// Frame indices in [ExtractionResult] are relative to the trim start, so
/// any later frame-fetch must pass the same [startMs] (see
/// [fetchFrameJpegAtIndex]).
Future<ExtractionResult> extractPose(
  String videoPath, {
  double fps = 15.0,
  int? startMs,
  int? endMs,
  void Function(int done, int total)? onProgress,
}) async {
  final Stopwatch sw = Stopwatch()..start();

  int durMs;
  try {
    durMs = await _videoDurationMs(videoPath);
  } catch (e) {
    throw Exception('[step:duration] $e');
  }
  if (durMs <= 0) {
    throw Exception('[step:duration] video duration zero: $videoPath');
  }
  final int sMs = (startMs ?? 0).clamp(0, durMs);
  final int eMs = (endMs ?? durMs).clamp(sMs, durMs);
  final int windowMs = eMs - sMs;
  if (windowMs <= 0) {
    throw Exception('[step:duration] empty trim window: ${sMs}ms..${eMs}ms');
  }
  final int frameStepMs = (1000.0 / fps).round();
  final int nFrames = (windowMs / frameStepMs).floor();

  _WorkerPool pool;
  try {
    pool = await _getPool();
  } catch (e) {
    throw Exception('[step:worker_pool_init] $e');
  }

  final List<PoseFrame> frames = List<PoseFrame>.filled(
    nFrames,
    PoseFrame.empty(0, 0, 0),
    growable: false,
  );
  int w = 0, h = 0;
  int detected = 0;
  int doneCount = 0;

  Future<void> processFrame(int i) async {
    final int tMs = sMs + i * frameStepMs;
    Uint8List? jpeg;
    try {
      jpeg = await _getFrameJpeg(videoPath, tMs);
    } catch (e) {
      if (i == 0) throw Exception('[step:native_frame0] $e');
      jpeg = null;
    }
    if (jpeg == null || jpeg.length < 100) {
      frames[i] = PoseFrame.empty(i, w, h);
      return;
    }
    final _WorkerResult res = await pool.submit(i, jpeg);
    if (res.error != null && i == 0) {
      throw Exception('[step:movenet_worker_frame0] ${res.error}');
    }
    if (w == 0 || h == 0) {
      w = res.origW;
      h = res.origH;
    }
    final List<List<double>> kp = res.keypoints;
    final bool anyConf = kp.any((List<double> j) => j[2] > 0.1);
    if (anyConf) detected++;
    frames[i] = PoseFrame(
      frameIndex: i,
      width: res.origW,
      height: res.origH,
      keypoints: kp,
    );
  }

  // Process frames in 4 parallel streams (matches kInFlight = pool size + 1).
  // Each stream walks frames sequentially; 4 streams keep the 3 workers busy
  // plus 1 in-flight native fetch overlap.
  const int kStreams = 4;
  final List<Future<void>> streams = <Future<void>>[];
  for (int s = 0; s < kStreams; s++) {
    streams.add(() async {
      for (int i = s; i < nFrames; i += kStreams) {
        try {
          await processFrame(i);
        } catch (e) {
          rethrow;
        }
        doneCount++;
        if (onProgress != null) onProgress(doneCount, nFrames);
      }
    }());
  }
  await Future.wait(streams);

  sw.stop();
  return ExtractionResult(
    frames: frames,
    width: w,
    height: h,
    detectionRate: frames.isEmpty ? 0.0 : detected / frames.length,
    extractSeconds: sw.elapsedMilliseconds / 1000.0,
  );
}
