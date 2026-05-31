"""Rulebook tip-bank selection + deterministic fallback composition.

The LLM's job is only to *stitch* the sentences SELECTED here into one natural
paragraph — it never free-generates coaching. With the LLM off/unavailable,
`compose_fallback()` emits the selected sentences verbatim as a paragraph.

Consumed by scripts/score_server.py. The Dart twin lives at
flutter_app/lib/rulebook_tips.dart and MUST stay behaviourally equivalent
(same severity buckets, same selection order, same fallback joining).

Selection key: stroke -> axis -> criterion/star -> severity bucket.
"""
from __future__ import annotations
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RULEBOOK_PATH = ROOT / "scripts" / "rulebook_tips.json"

# Canonical posture-criterion order (matches rule_based_scorer.CRITERIA_NAMES).
CRITERIA_ORDER = [
    "peak_wrist_above_shoulder",
    "elbow_extension_>=160deg",
    "hip_rotation_>=20deg",
    "knees_bent_at_prep",
]  # head_stable (C5) removed 2026-05-31
MAJOR_FAIL_PROB = 0.30  # probability below this == "major_fail", else "minor_fail"


def load_rulebook(path: Path | None = None) -> dict:
    p = path or RULEBOOK_PATH
    return json.loads(p.read_text(encoding="utf-8"))


def criterion_severity(c: dict) -> str:
    """One of 'na' | 'pass' | 'minor_fail' | 'major_fail'."""
    if c.get("measurement") is None or c.get("pass") is None:
        return "na"
    if c.get("pass"):
        return "pass"
    prob = float(c.get("probability", 0.5))
    return "major_fail" if prob < MAJOR_FAIL_PROB else "minor_fail"


def _bank_text(rulebook: dict, stroke: str, axis: str, key: str, severity: str, idx: int = 0) -> str | None:
    strokes = rulebook.get("strokes", {})
    entry = strokes.get(stroke) or strokes.get("unknown_ood") or {}
    bucket = (((entry.get(axis) or {}).get(key)) or {}).get(severity)
    if isinstance(bucket, list) and bucket:
        return bucket[idx % len(bucket)]  # pick one variant (seeded), never two
    return None


def select_sentences(payload: dict, rulebook: dict, seed: int = 0) -> list[dict]:
    """Return ordered [{axis, criterion, severity, text}] selected from the bank.

    Surfaces failing/NA posture criteria + non-average speed/step (only for axes
    in `axes_evaluated`), mirroring the existing coaching_tips policy. If nothing
    is wrong, returns a single 'all_good' encouragement so the user always gets
    coaching.
    """
    stroke = (payload.get("stroke") or {}).get("label") or "unknown_ood"
    axes_eval = payload.get("axes_evaluated") or ["posture", "speed", "step"]
    out: list[dict] = []

    if "posture" in axes_eval:
        by_name = {c.get("name"): c for c in payload.get("posture_criteria", [])}
        for pos, name in enumerate(CRITERIA_ORDER):
            c = by_name.get(name)
            if c is None:
                continue
            sev = criterion_severity(c)
            if sev in ("pass", "na"):
                # pass → positives; na (joint not tracked) → say nothing (confusing).
                continue
            idx = seed + pos  # per-criterion offset so cells can show different variants
            text = _bank_text(rulebook, stroke, "posture", name, sev, idx) \
                or _bank_text(rulebook, stroke, "posture", name, "major_fail", idx)
            if text:
                out.append({"axis": "posture", "criterion": name, "severity": sev, "text": text})

    for axis, star_key in (("speed", "speed_stars"), ("step", "step_stars")):
        if axis not in axes_eval:
            continue
        star = payload.get(star_key)
        if star is None or int(star) >= 3:
            continue  # corrections only for 1-2 (needs work); 4-5 (good) → positives
        # axis buckets are keyed directly by star (axis -> "1".."5" -> [phrasings]).
        strokes = rulebook.get("strokes", {})
        entry = strokes.get(stroke) or strokes.get("unknown_ood") or {}
        bucket = (entry.get(axis) or {}).get(str(int(star)))
        text = bucket[(seed + int(star)) % len(bucket)] if isinstance(bucket, list) and bucket else None
        if text:
            out.append({"axis": axis, "criterion": axis, "severity": f"star{int(star)}", "text": text})

    if not out:
        out.append({"axis": "summary", "criterion": "all_good", "severity": "pass",
                    "text": rulebook.get("all_good_default", "좋은 자세예요.")})
    return out


def select_positives(payload: dict, rulebook: dict, seed: int = 0) -> list[dict]:
    """Return [{axis, criterion, text}] 'doing well' notes for criteria that PASS
    (within evaluated axes) + good speed/step. Surfaced as a separate positive
    signal so the user always sees what they did right, not only corrections."""
    stroke = (payload.get("stroke") or {}).get("label") or "unknown_ood"
    axes_eval = payload.get("axes_evaluated") or ["posture", "speed", "step"]
    out: list[dict] = []
    if "posture" in axes_eval:
        by_name = {c.get("name"): c for c in payload.get("posture_criteria", [])}
        for pos, name in enumerate(CRITERIA_ORDER):
            c = by_name.get(name)
            if c is None or criterion_severity(c) != "pass":
                continue
            text = _bank_text(rulebook, stroke, "posture", name, "pass", seed + pos)
            if text:
                out.append({"axis": "posture", "criterion": name, "text": text})
    for axis, star_key in (("speed", "speed_stars"), ("step", "step_stars")):
        if axis not in axes_eval:
            continue
        star = payload.get(star_key)
        if star is None or int(star) < 4:
            continue  # only 4-5 stars count as "doing well"
        strokes = rulebook.get("strokes", {})
        entry = strokes.get(stroke) or {}
        bucket = (entry.get(axis) or {}).get(str(int(star)))
        if isinstance(bucket, list) and bucket:
            out.append({"axis": axis, "criterion": axis, "text": bucket[(seed + int(star)) % len(bucket)]})
    return out


def compose_fallback(sentences: list[dict]) -> str:
    """Deterministic paragraph = selected bank sentences joined verbatim.

    Each bank sentence is a complete polite Korean sentence, so a plain space
    join already reads as one coherent paragraph — no new content introduced.
    """
    return " ".join(s["text"].strip() for s in sentences if s.get("text"))


def forbidden_keywords(rulebook: dict, stroke: str) -> list[str]:
    g = (rulebook.get("guardrails") or {}).get(stroke) or {}
    return list(g.get("forbidden_keywords", []))


def introduced_forbidden(candidate: str, allowed_text: str, forbidden: list[str]) -> list[str]:
    """Forbidden tokens present in `candidate` but NOT in `allowed_text` (the vetted
    source sentences). Session B's fix_ko legitimately NEGATE some forbidden tokens
    (e.g. '어깨 위로 올리지 마세요'); those are allowed because they already appear in
    the source. Only tokens the LLM *introduced* beyond the source are real
    violations — that's what we discard the smoothed paragraph for."""
    return [k for k in forbidden if k in candidate and k not in allowed_text]


def _self_test() -> int:
    """Sanity checks: selection order, axis gating, and the short_serve guardrail
    (no power/footwork leakage). Run: python scripts/rulebook.py"""
    rb = load_rulebook()
    ok = True

    payload = {
        "stroke": {"label": "high_clear"},
        "axes_evaluated": ["posture", "speed", "step"],
        "posture_criteria": [
            {"name": "peak_wrist_above_shoulder", "pass": True, "measurement": 0.3, "probability": 0.9},
            {"name": "elbow_extension_>=160deg", "pass": False, "measurement": 90, "probability": 0.1},
            {"name": "hip_rotation_>=20deg", "pass": False, "measurement": 10, "probability": 0.45},
            {"name": "knees_bent_at_prep", "pass": None, "measurement": None, "probability": 0.5},
            {"name": "head_stable", "pass": True, "measurement": 0.02, "probability": 0.8},
        ],
        "speed_stars": 2, "step_stars": 5,
    }
    got = [f"{s['axis']}:{s['criterion']}:{s['severity']}" for s in select_sentences(payload, rb)]
    # knees na → skipped; step star5 (good) → skipped (goes to positives); speed star2 → kept.
    exp = ["posture:elbow_extension_>=160deg:major_fail", "posture:hip_rotation_>=20deg:minor_fail",
           "speed:speed:star2"]
    print(f"[{'OK' if got == exp else 'FAIL'}] selection order")
    ok = ok and got == exp

    serve = {
        "stroke": {"label": "short_serve"}, "axes_evaluated": ["posture"],
        "posture_criteria": [{"name": n, "pass": False, "measurement": 5.0, "probability": 0.1}
                             for n in CRITERIA_ORDER],
        "speed_stars": 1, "step_stars": 1,
    }
    fb = compose_fallback(select_sentences(serve, rb))
    forb = forbidden_keywords(rb, "short_serve")
    # Fallback (verbatim B sentences) must introduce NOTHING beyond itself.
    fb_intro = introduced_forbidden(fb, fb, forb)
    print(f"[{'OK' if not fb_intro else 'FAIL'}] short_serve fallback introduces no forbidden token")
    ok = ok and not fb_intro
    # An LLM that ADDS power/footwork advice is caught; one that only echoes B is kept.
    bad = fb + " 더 강하게 파워로 치고 발을 움직여 스텝을 밟으세요."
    bad_intro = introduced_forbidden(bad, fb, forb)
    good_intro = introduced_forbidden(fb, fb, forb)
    caught = ("파워" in bad_intro) and not good_intro
    print(f"[{'OK' if caught else 'FAIL'}] guardrail catches LLM-introduced tokens (introduced={bad_intro[:4]})")
    ok = ok and caught

    allgood = {"stroke": {"label": "high_clear"}, "axes_evaluated": ["posture", "speed", "step"],
               "posture_criteria": [{"name": n, "pass": True, "measurement": 1.0, "probability": 0.8}
                                    for n in CRITERIA_ORDER],
               "speed_stars": 3, "step_stars": 3}
    sel = select_sentences(allgood, rb)
    print(f"[{'OK' if len(sel) == 1 and sel[0]['criterion'] == 'all_good' else 'FAIL'}] all-good encouragement")
    ok = ok and len(sel) == 1 and sel[0]["criterion"] == "all_good"

    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(_self_test())
