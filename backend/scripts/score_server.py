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

from rulebook import (
    compose_fallback,
    forbidden_keywords,
    introduced_forbidden,
    load_rulebook,
    select_positives,
    select_sentences,
)

ROOT = Path(__file__).resolve().parent.parent
SCORE_CLIP = ROOT / "experiments" / "demo_v4" / "score_clip.py"
STROKE_AXES = ROOT / "scripts" / "stroke_axes.json"
PY = sys.executable

VALID_STROKES = {"high_clear", "short_serve", "forehand_drive"}

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("score_server")

app = Flask(__name__)
app.config["MAX_CONTENT_LENGTH"] = 200 * 1024 * 1024  # 200 MB upload cap


GROQ_URL = "https://api.groq.com/openai/v1/chat/completions"
GROQ_MODEL = "llama-3.1-8b-instant"


_ALL_AXES = ["posture", "speed", "step"]
_AXIS_KO = {"posture": "자세", "speed": "속도/스윙 스피드", "step": "스텝/풋워크"}


def _apply_stroke_axis_filter(payload: dict) -> dict:
    """Local re-implementation of score_clip.apply_stroke_axis_filter so the server
    can re-filter after a user stroke override WITHOUT importing the torch/cv2-heavy
    score_clip module. Behaviour must match scripts/stroke_axes.json semantics and
    flutter_app/lib/axis_filter.dart."""
    try:
        cfg = json.loads(STROKE_AXES.read_text(encoding="utf-8"))
    except Exception:
        cfg = {}
    label = (payload.get("stroke") or {}).get("label") or ""
    entry = cfg.get(label) or cfg.get("unknown_ood") or {"axes": _ALL_AXES, "reasons": {}}
    relevant = list(entry.get("axes", _ALL_AXES))
    reasons = {k: str(v) for k, v in (entry.get("reasons") or {}).items()}
    for axis in _ALL_AXES:
        # Dropped axes: omit *_stars/*_reason entirely (no N/A). Reason kept in axes_dropped.
        if axis not in relevant:
            payload.pop(f"{axis}_stars", None)
        payload.pop(f"{axis}_reason", None)
    payload["coaching_tips"] = [
        t for t in payload.get("coaching_tips", []) if t.get("axis") in relevant
    ]
    payload["axes_evaluated"] = relevant
    payload["axes_dropped"] = {
        a: reasons.get(a, f"{a} not relevant for {label}")
        for a in _ALL_AXES if a not in relevant
    }
    return payload


def _maybe_override_stroke(payload: dict, override: str) -> dict:
    """If the user explicitly picked a stroke, make it authoritative: stash the
    classifier output under stroke.classifier_reference (kept for transparency)
    and re-run the axis filter for the chosen stroke. The ST-GCN/OOD result is
    thus bypassed for scoring decisions (점5)."""
    override = (override or "").strip()
    if override not in VALID_STROKES:
        return payload  # no/invalid override → keep classifier label
    stroke = payload.get("stroke") or {}
    if stroke.get("label") != override:
        stroke["classifier_reference"] = {
            "label": stroke.get("label"),
            "top1_confidence": stroke.get("top1_confidence"),
            "softmax_3class": stroke.get("softmax_3class"),
            "is_ood": stroke.get("is_ood"),
        }
        stroke["label"] = override
        stroke["source"] = "user_selected"
        payload["stroke"] = stroke
        _apply_stroke_axis_filter(payload)
    else:
        stroke["source"] = "user_selected"
        payload["stroke"] = stroke
    return payload


def _smooth_with_groq(sentences: list, fallback: str, forbidden: list,
                      timeout_s: float = 8.0) -> dict:
    """Ask Groq to ONLY stitch the already-selected rulebook sentences into one
    natural paragraph — no free generation, no new advice/numbers. Returns
    {'paragraph': ...} on success or {'skipped': True, 'reason': ...}."""
    key = os.environ.get("GROQ_API_KEY", "").strip()
    if not key:
        return {"skipped": True, "reason": "GROQ_API_KEY env var not set"}
    if not sentences:
        return {"skipped": True, "reason": "no rulebook sentences to stitch"}
    bullet_lines = "\n".join(f"- {s['text']}" for s in sentences)
    forbid_block = ""
    if forbidden:
        forbid_block = ("절대 사용하면 안 되는 표현(이 단어가 들어가면 잘못된 조언이 됨): "
                        + ", ".join(forbidden) + "\n")
    prompt = f"""너는 한국어 배드민턴 코치의 말을 다듬는 편집자다.
아래 '코칭 문장'들은 규칙 기반 분석이 이미 선택한 조언이다.
규칙:
1. 문장들의 의미를 절대 바꾸지 마라.
2. 새로운 조언·숫자·측정값·칭찬을 추가하지 마라. 주어진 내용만 사용해라.
3. 존댓말로, 자연스럽게 이어지는 한 단락(2~4문장)으로만 연결해라.
{forbid_block}코칭 문장:
{bullet_lines}

다듬은 한 단락만 출력해라(설명·머리말 없이)."""
    body = {
        "model": GROQ_MODEL,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": 200,
        "temperature": 0.3,
    }
    req = urllib.request.Request(
        GROQ_URL,
        data=json.dumps(body).encode("utf-8"),
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
        rbody = json.loads(raw)
        paragraph = rbody["choices"][0]["message"]["content"].strip()
        return {
            "paragraph": paragraph,
            "latency_ms": elapsed_ms,
            "model": GROQ_MODEL,
            "tokens_used": rbody.get("usage", {}),
        }
    except urllib.error.HTTPError as e:
        return {"skipped": True, "reason": f"Groq HTTP {e.code}: {e.reason}"}
    except Exception as e:
        return {"skipped": True, "reason": f"Groq call failed: {type(e).__name__}: {e}"}


def _compose_coaching(score: dict) -> dict:
    """Rulebook-grounded coaching. Selects bank sentences (deterministic), then
    EITHER stitches them via the LLM OR falls back to the verbatim join. The final
    paragraph is always grounded in the bank — the LLM never adds content.

    Returns {'sentences', 'paragraph', 'paragraph_fallback', 'source', 'llm'}.
    """
    rulebook = load_rulebook()
    stroke = (score.get("stroke") or {}).get("label") or "unknown_ood"
    sentences = select_sentences(score, rulebook)
    fallback = compose_fallback(sentences)
    forbidden = forbidden_keywords(rulebook, stroke)
    # Only forbid tokens the source DOESN'T already (correctly) use — B's fix_ko
    # negate some forbidden tokens, which is fine; we only stop the LLM adding new ones.
    prompt_forbidden = [k for k in forbidden if k not in fallback]

    llm = _smooth_with_groq(sentences, fallback, prompt_forbidden)
    paragraph, source = fallback, "fallback"
    if llm.get("paragraph"):
        smoothed = llm["paragraph"]
        introduced = introduced_forbidden(smoothed, fallback, forbidden)
        if introduced:
            # LLM introduced a forbidden token beyond the source → discard, use bank join.
            llm = {"skipped": True,
                   "reason": f"smoothed output introduced forbidden keyword '{introduced[0]}'; used fallback",
                   "discarded_paragraph": smoothed}
        else:
            paragraph, source = smoothed, "llm"
    return {
        "sentences": sentences,
        "positives": select_positives(score, rulebook),
        "paragraph": paragraph,
        "paragraph_fallback": fallback,
        "source": source,
        "llm": llm,
    }


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

    # 점5: honour a user-selected stroke (bypass classifier for scoring decisions).
    override = request.form.get("stroke", "")
    payload = _maybe_override_stroke(payload, override)
    if payload.get("stroke", {}).get("source") == "user_selected":
        log.info(f"[{request_id}] stroke overridden by user -> {payload['stroke']['label']}")

    # 점6: rulebook-grounded coaching (LLM stitches selected bank sentences; else fallback).
    payload["rulebook"] = _compose_coaching(payload)
    # Backward-compat: keep payload['llm'] for the existing UI block.
    payload["llm"] = payload["rulebook"]["llm"]
    if payload["rulebook"]["source"] == "llm":
        log.info(f"[{request_id}] coaching: LLM-stitched {payload['llm'].get('latency_ms')}ms")
    else:
        log.info(f"[{request_id}] coaching: deterministic fallback ({payload['llm'].get('reason')})")

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
