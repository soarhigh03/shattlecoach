// On-device Groq LLM client — STITCHES the already-selected rulebook sentences
// into one natural Korean paragraph. It never free-generates: no new advice,
// numbers, or praise. If the key is absent, the network fails, or the model
// introduces a forbidden keyword, the caller falls back to the deterministic
// verbatim join (rulebook_tips.dart composeFallback).
//
// The API key is injected at BUILD time via --dart-define=GROQ_API_KEY=... (see
// build_apk.ps1, sourced from .env). It is NOT read from the UI and NOT stored
// in the repo. The key still ends up inside the compiled APK, so treat it as a
// shared throwaway Groq free-tier key — rotate it if it leaks.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

/// Groq endpoint + model. Mirrors backend/scripts/score_server.py.
const String kGroqUrl = 'https://api.groq.com/openai/v1/chat/completions';
const String kGroqModel = 'llama-3.1-8b-instant';

/// Build-time injected key. Empty unless `--dart-define=GROQ_API_KEY=...` was
/// passed at build time. const so it's tree-shaken into the binary.
const String _kBuildTimeGroqApiKey =
    String.fromEnvironment('GROQ_API_KEY', defaultValue: '');

/// Resolve the Groq key from either the build-time const (preferred, tree-
/// shaken) or — for local dev — `GROQ_API_KEY` in the bundled `.env`. Returns
/// the empty string if neither is set; callers then fall back to the rulebook.
String _resolvedGroqApiKey() {
  final String build = _kBuildTimeGroqApiKey.trim();
  if (build.isNotEmpty) return build;
  try {
    return (dotenv.env['GROQ_API_KEY'] ?? '').trim();
  } catch (_) {
    // dotenv not initialised — fine, just means no runtime fallback available.
    return '';
  }
}

/// Result of an LLM smoothing attempt.
class LlmResult {
  /// The smoothed paragraph, or null if skipped/failed.
  final String? paragraph;

  /// True when no LLM paragraph was produced (key missing, network error,
  /// empty input, or guardrail rejection). [reason] explains why.
  final bool skipped;
  final String? reason;
  final int? latencyMs;
  final String model;

  const LlmResult({
    this.paragraph,
    this.skipped = false,
    this.reason,
    this.latencyMs,
    this.model = kGroqModel,
  });

  factory LlmResult.skip(String reason) =>
      LlmResult(skipped: true, reason: reason);

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (paragraph != null) 'paragraph': paragraph,
        'skipped': skipped,
        if (reason != null) 'reason': reason,
        if (latencyMs != null) 'latency_ms': latencyMs,
        'model': model,
      };
}

class GroqCoach {
  GroqCoach._();

  /// Whether a Groq key is available (build-time const or runtime `.env`).
  /// UI/pipeline can use this to decide whether to even attempt a network call.
  static bool get hasKey => _resolvedGroqApiKey().isNotEmpty;

  /// Ask Groq to stitch [sentenceTexts] (already-selected rulebook sentences)
  /// into one polite Korean paragraph. [forbidden] lists words the model must
  /// not introduce. Returns [LlmResult] — never throws.
  static Future<LlmResult> smooth({
    required List<String> sentenceTexts,
    List<String> forbidden = const <String>[],
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final String key = _resolvedGroqApiKey();
    if (key.isEmpty) {
      return LlmResult.skip('GROQ_API_KEY not set (build-time or .env)');
    }
    final List<String> bullets =
        sentenceTexts.map((String s) => s.trim()).where((String s) => s.isNotEmpty).toList();
    if (bullets.isEmpty) {
      return LlmResult.skip('no rulebook sentences to stitch');
    }

    final String bulletLines = bullets.map((String s) => '- $s').join('\n');
    final String forbidBlock = forbidden.isEmpty
        ? ''
        : '절대 사용하면 안 되는 표현(이 단어가 들어가면 잘못된 조언이 됨): '
            '${forbidden.join(", ")}\n';
    final String prompt = '''너는 한국어 배드민턴 코치의 말을 다듬는 편집자다.
아래 '코칭 문장'들은 규칙 기반 분석이 이미 선택한 조언이다.
규칙:
1. 문장들의 의미를 절대 바꾸지 마라.
2. 새로운 조언·숫자·측정값·칭찬을 추가하지 마라. 주어진 내용만 사용해라.
3. 존댓말로, 자연스럽게 이어지는 한 단락(2~4문장)으로만 연결해라.
$forbidBlock코칭 문장:
$bulletLines

다듬은 한 단락만 출력해라(설명·머리말 없이).''';

    final Map<String, dynamic> body = <String, dynamic>{
      'model': kGroqModel,
      'messages': <Map<String, String>>[
        <String, String>{'role': 'user', 'content': prompt},
      ],
      'max_tokens': 200,
      'temperature': 0.3,
    };

    final Stopwatch sw = Stopwatch()..start();
    try {
      final http.Response resp = await http
          .post(
            Uri.parse(kGroqUrl),
            headers: <String, String>{
              'Authorization': 'Bearer $key',
              'Content-Type': 'application/json',
              // Cloudflare 1010 blocks default UAs — set an explicit one.
              'User-Agent': 'shattlecoach/0.1 (+on-device)',
            },
            body: jsonEncode(body),
          )
          .timeout(timeout);
      sw.stop();
      if (resp.statusCode != 200) {
        return LlmResult.skip('Groq HTTP ${resp.statusCode}');
      }
      final Map<String, dynamic> rbody =
          jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      final String paragraph = (((rbody['choices'] as List<dynamic>?)?.first
                  as Map<String, dynamic>?)?['message'] as Map<String, dynamic>?)?['content']
              ?.toString()
              .trim() ??
          '';
      if (paragraph.isEmpty) {
        return LlmResult.skip('Groq returned empty content');
      }
      return LlmResult(
        paragraph: paragraph,
        latencyMs: sw.elapsedMilliseconds,
      );
    } on TimeoutException {
      return LlmResult.skip('Groq timeout (${timeout.inSeconds}s)');
    } catch (e) {
      return LlmResult.skip('Groq call failed: ${e.runtimeType}');
    }
  }
}
