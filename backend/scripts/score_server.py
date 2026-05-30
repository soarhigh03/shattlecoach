"""V4-EB1. Flask server wrapping experiments/demo_v4/score_clip.py.

Endpoints:
  GET  /health          → {'status':'ok','version':'v4'}
  POST /score           → multipart upload (field: file). Returns score JSON
                          containing BOTH rule-based tips (v0) AND optional
                          LLM-augmented natural coaching paragraph (v1) when
                          GROQ_API_KEY env var is set.

The Flutter mini app POSTs a video here over `adb reverse` so the phone's
localhost:8765 is forwarded to the PC's localhost:8765 — no LAN config needed,
just USB.

LLM (v1): if GROQ_API_KEY is set in the environment, the server calls Groq's
free Llama-3.1-8b-instant model to convert the rule-based output into a
natural Korean coaching paragraph. UI shows v0 + v1 side-by-side so a
single test iteration compares both.

Usage:
  python scripts/score_server.py
  $env:GROQ_API_KEY = "gsk_..."  ; python scripts/score_server.py
"""
from __future__ import annotations
import argparse
import json
import logging
import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path

from flask import Flask, jsonify, request

ROOT = Path(__file__).resolve().parent.parent
SCORE_CLIP = ROOT / "experiments" / "demo_v4" / "score_clip.py"
PY = sys.executable

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("score_server")

app = Flask(__name__)
app.config["MAX_CONTENT_LENGTH"] = 200 * 1024 * 1024  # 200 MB upload cap


GROQ_URL = "https://api.groq.com/openai/v1/chat/completions"
GROQ_MODEL = "llama-3.1-8b-instant"


def _call_groq(score: dict, timeout_s: float = 8.0) -> dict:
    """Returns {'paragraph': '...', 'latency_ms': N, 'model': 'llama-3.1-8b-instant'}
    OR {'skipped': True, 'reason': '...'} if API key missing / call fails.

    Sends ONLY the score JSON (no video, no skeleton coordinates) — privacy-safe.
    """
    key = os.environ.get("GROQ_API_KEY", "").strip()
    if not key:
        return {"skipped": True, "reason": "GROQ_API_KEY env var not set"}
    stroke = score.get("stroke", {})
    axes_evaluated = score.get("axes_evaluated", ["posture", "speed", "step"])
    axes_dropped = score.get("axes_dropped", {})
    # tips were already filtered upstream by score_clip.apply_stroke_axis_filter
    tips = [t for t in score.get("coaching_tips", []) if t.get("axis") in axes_evaluated]
    if not tips:
        return {"skipped": True, "reason": "no rule-based tips to expand"}
    measurements = []
    for c in score.get("posture_criteria", []):
        m = c.get("measurement")
        if m is None:
            measurements.append(f"- {c.get('name')}: 측정 불가 (관절 인식 실패)")
        else:
            passed = "✓통과" if c.get("pass") else "✗실패"
            measurements.append(
                f"- {c.get('name')}: {m:.2f} {c.get('unit', '')} "
                f"(임계값 {c.get('threshold', '?')}, {passed})"
            )
    fail_lines = "\n".join(
        f"- [{t.get('axis')}] {t.get('tip_ko')}" for t in tips
    )
    star_lines = []
    if "posture" in axes_evaluated:
        star_lines.append(f"- 자세 별점: {score.get('posture_stars', '?')}/5")
    if "speed" in axes_evaluated:
        star_lines.append(f"- 속도 별점: {score.get('speed_stars', '?')}/5")
    if "step" in axes_evaluated:
        star_lines.append(f"- 스텝 별점: {score.get('step_stars', '?')}/5")
    # GUARDRAIL — explicit forbidden axes with reasons
    if axes_dropped:
        forbidden_axis_ko = {"posture": "자세", "speed": "속도/스윙 스피드", "step": "스텝/풋워크"}
        forbidden_lines = "\n".join(
            f"- {forbidden_axis_ko.get(a, a)} ({reason})" for a, reason in axes_dropped.items()
        )
        guardrail = (
            "\n중요: 아래 축은 이 스트로크에 무관하므로 절대 언급하지 마라 "
            "(언급하면 잘못된 조언이 됨):\n" + forbidden_lines + "\n"
        )
    else:
        guardrail = ""
    prompt = f"""너는 한국어 배드민턴 코치다. 짧고 친근한 톤으로 2-3문장의 조언을 해라.
존댓말, 100자 이내. 측정값을 1-2개 인용해서 구체적으로.

분석 결과:
- 예측 스트로크: {stroke.get('label', '?')} (확신도 {stroke.get('top1_confidence', 0):.2f})
{chr(10).join(star_lines)}
{guardrail}
5개 기준 측정값:
{chr(10).join(measurements)}

실패 항목과 룰북 조언:
{fail_lines}

위를 참고해서 자연스러운 한국어 한 단락으로 코칭해라. 측정값 1-2개 언급 필수.
"""
    payload = {
        "model": GROQ_MODEL,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": 200,
        "temperature": 0.4,
    }
    req = urllib.request.Request(
        GROQ_URL,
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {key}",
            "Content-Type": "application/json",
            "User-Agent": "shattlecoach/0.1 (+local-server)",
        },
        method="POST",
    )
    t0 = time.perf_counter()
    try:
        with urllib.request.urlopen(req, timeout=timeout_s) as resp:
            raw = resp.read().decode("utf-8")
        elapsed_ms = int((time.perf_counter() - t0) * 1000)
        body = json.loads(raw)
        paragraph = body["choices"][0]["message"]["content"].strip()
        return {
            "paragraph": paragraph,
            "latency_ms": elapsed_ms,
            "model": GROQ_MODEL,
            "tokens_used": body.get("usage", {}),
        }
    except urllib.error.HTTPError as e:
        return {"skipped": True, "reason": f"Groq HTTP {e.code}: {e.reason}"}
    except Exception as e:
        return {"skipped": True, "reason": f"Groq call failed: {type(e).__name__}: {e}"}


@app.route("/health", methods=["GET"])
def health():
    return jsonify({
        "status": "ok", "version": "v4",
        "score_clip": str(SCORE_CLIP),
        "groq_available": bool(os.environ.get("GROQ_API_KEY", "").strip()),
        "groq_model": GROQ_MODEL,
    })


@app.route("/score", methods=["POST"])
def score():
    if "file" not in request.files:
        return jsonify({"status": "ERROR", "error": "no 'file' field in multipart upload"}), 400
    f = request.files["file"]
    if not f.filename:
        return jsonify({"status": "ERROR", "error": "empty filename"}), 400

    request_id = uuid.uuid4().hex[:10]
    tmp_dir = Path(tempfile.gettempdir()) / "shattlecoach_uploads"
    tmp_dir.mkdir(parents=True, exist_ok=True)
    video_path = tmp_dir / f"{request_id}.mp4"
    f.save(video_path)
    size_mb = round(video_path.stat().st_size / 1024 / 1024, 2)
    log.info(f"[{request_id}] received {f.filename} -> {video_path} ({size_mb} MB)")

    out_dir = tmp_dir / f"{request_id}_out"
    out_dir.mkdir(parents=True, exist_ok=True)

    cmd = [PY, str(SCORE_CLIP), "--video", str(video_path), "--out_dir", str(out_dir)]
    t0 = time.perf_counter()
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=180,
                              encoding="utf-8", errors="replace")
    except subprocess.TimeoutExpired:
        log.error(f"[{request_id}] score_clip timed out")
        return jsonify({"status": "ERROR", "error": "score_clip timed out (>180s)"}), 500
    elapsed = time.perf_counter() - t0
    if proc.returncode != 0:
        log.error(f"[{request_id}] score_clip exit {proc.returncode}: {proc.stderr[-400:]}")
        return jsonify({"status": "ERROR", "error": f"score_clip exit {proc.returncode}",
                        "stderr_tail": proc.stderr[-400:]}), 500

    score_path = out_dir / f"{video_path.stem}_score.json"
    if not score_path.exists():
        return jsonify({"status": "ERROR", "error": f"score json not produced: {score_path}"}), 500
    try:
        payload = json.loads(score_path.read_text(encoding="utf-8"))
    except Exception as e:
        return jsonify({"status": "ERROR", "error": f"json parse failed: {e}"}), 500

    log.info(f"[{request_id}] scored in {elapsed:.2f}s — stroke={payload.get('stroke', {}).get('label')}")
    payload["server_processing_seconds"] = round(elapsed, 3)
    payload["request_id"] = request_id

    # v1: Groq LLM augmentation (optional, skip if no API key or empty tips)
    payload["llm"] = _call_groq(payload)
    if payload["llm"].get("paragraph"):
        log.info(f"[{request_id}] LLM paragraph: {payload['llm']['latency_ms']}ms")
    else:
        log.info(f"[{request_id}] LLM skipped: {payload['llm'].get('reason')}")

    # Cleanup older request dirs (best-effort)
    try:
        for old in tmp_dir.glob("*_out"):
            if old.is_dir() and old != out_dir:
                if time.time() - old.stat().st_mtime > 600:
                    shutil.rmtree(old, ignore_errors=True)
    except Exception:
        pass

    return jsonify(payload), 200


@app.errorhandler(413)
def too_large(_):
    return jsonify({"status": "ERROR", "error": "upload too large (200 MB cap)"}), 413


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--host", default="0.0.0.0")
    args = ap.parse_args()
    log.info(f"score_server listening on {args.host}:{args.port}")
    log.info(f"  POST /score (multipart 'file') -> demo_v4 score JSON")
    log.info(f"  GET  /health")
    log.info(f"  score_clip: {SCORE_CLIP}")
    app.run(host=args.host, port=args.port, debug=False, threaded=True)


if __name__ == "__main__":
    main()
