"""Regenerate scripts/rulebook_tips.json from data/coaching_knowledge.json (Session B)
+ the VARIANT augmentation below.

Why variants: with only 4 geometric criteria (C1-C4) × {pass, minor_fail, major_fail}
× 3 strokes + speed/step star buckets, the coaching CASE SPACE is finite and fully
enumerable — every cell already has a sentence. The augmentation adds a 2nd phrasing
per cell so the app doesn't always say the exact same thing. Selection picks ONE
variant per cell (seeded by the clip), so two variants of the same point never appear
together.

Content sources:
  variant #1 (v1) = coaching_knowledge.json  (good / fix_ko / fix_ko_minor)
  variant #2 (v2) = POSTURE_V2 / SPEED_STEP below (Session C augmentation)

Run: python scripts/gen_rulebook_tips.py   (writes scripts/rulebook_tips.json)
Then mirror to flutter_app/assets/rulebook_tips.json.
"""
from __future__ import annotations
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
# coaching_knowledge.json lives at the repo-root data/ in both layouts (old-layout
# repo root and backend/ — where it resolves one level up).
CK = ROOT / "data" / "coaching_knowledge.json"
if not CK.exists():
    CK = ROOT.parent / "data" / "coaching_knowledge.json"
CUR = Path(__file__).resolve().parent / "rulebook_tips.json"
OUT = CUR

CRITERIA = ["peak_wrist_above_shoulder", "elbow_extension_>=160deg",
            "hip_rotation_>=20deg", "knees_bent_at_prep"]  # head_stable (C5) removed
STROKES = ["high_clear", "short_serve", "forehand_drive"]

# "Doing well" (pass) variant #1 = the coaching_knowledge `good` description (the
# informative ideal-form sentence), but with technical jargon clauses (e.g. the
# "숙련자 X-factor 약 47°" fragment) stripped — those read wrong in a praise list.
# variant #2 = the short congratulatory POSTURE_V2[...]["pass"].
_JARGON = ("X-factor", "factor")


def _clean_good(good: str) -> str:
    ko = (good or "").split(" / ")[0].strip()  # Korean side of "ko / en"
    parts = [p.strip() for p in ko.split(". ") if p.strip()]
    parts = [p for p in parts if not any(j.lower() in p.lower() for j in _JARGON)]
    out = ". ".join(parts).strip()
    if out and not out.endswith((".", "다", "요")):
        out += "."
    return out

# v2 phrasings per stroke × criterion × {pass, minor_fail, major_fail}. Same meaning,
# different wording — for variety only. (v1 comes from coaching_knowledge.json.)
POSTURE_V2 = {
  "high_clear": {
    "peak_wrist_above_shoulder": {
      "pass": "타점이 높고 앞에 잘 잡혀 있어요.",
      "minor_fail": "타점을 조금만 더 높고 앞에서 잡으면 타구가 더 깊어져요.",
      "major_fail": "임팩트가 머리 뒤에서 이뤄지고 있어요. 셔틀콕 아래로 빠르게 들어가 어깨 위·몸 앞 높은 타점에서 때리세요.",
    },
    "elbow_extension_>=160deg": {
      "pass": "팔 신전이 좋아 라켓 헤드 속도가 잘 나와요.",
      "minor_fail": "팔을 조금 더 펴서 라켓 끝 속도를 살려 보세요.",
      "major_fail": "임팩트에서 팔이 접혀 있어요. 팔을 거의 일직선으로 펴고 전완을 회내하며 던지듯 때리세요.",
    },
    "hip_rotation_>=20deg": {
      "pass": "몸통 회전으로 힘을 잘 만들어 내고 있어요.",
      "minor_fail": "골반 회전을 조금만 더 더해 주면 타구가 한결 깊어져요.",
      "major_fail": "팔 힘에만 의존하고 있어요. 옆으로 선 뒤 골반→몸통→어깨 순서로 회전을 풀어 그 힘을 라켓에 실으세요.",
    },
    "knees_bent_at_prep": {
      "pass": "낮은 준비 자세가 잘 잡혀 있어요.",
      "minor_fail": "무릎을 살짝만 더 굽히면 다음 동작으로 더 빠르게 이어져요.",
      "major_fail": "스탠스가 너무 높아요. 무릎을 굽혀 무게중심을 낮추면 점프와 이동이 빨라져요.",
    },
  },
  "short_serve": {
    "peak_wrist_above_shoulder": {
      "pass": "서브 타점이 낮고 안정적이에요.",
      "minor_fail": "타점 높이를 매번 일정하게, 허리 아래로 유지해 보세요.",
      "major_fail": "서브 타점이 너무 높아요. 셔틀콕을 허리 아래 허벅지 높이에서 부드럽게 맞히세요(규정).",
    },
    "elbow_extension_>=160deg": {
      "pass": "팔 힘을 빼고 부드럽게 잘 밀고 있어요.",
      "minor_fail": "팔에 힘을 빼고 손끝 감각으로 컨트롤해 보세요.",
      "major_fail": "팔을 쭉 펴서 휘두르지 마세요. 팔은 편하게 두고 손가락 감각으로 셔틀콕을 밀어 보내세요.",
    },
    "hip_rotation_>=20deg": {
      "pass": "몸통을 잘 고정해 서브가 일정해요.",
      "minor_fail": "회전을 줄이고 정확한 라켓 면으로 코스만 노려 보세요.",
      "major_fail": "상체를 크게 회전시키지 마세요. 몸통을 안정적으로 두고 라켓 면 컨트롤에 집중하세요.",
    },
    "knees_bent_at_prep": {
      "pass": "균형 잡힌 안정된 서브 자세예요.",
      "minor_fail": "무릎을 살짝 굽혀 균형을 잡으면 라켓 컨트롤이 안정돼요.",
      "major_fail": "다리가 뻣뻣하게 펴져 있어요. 무릎을 살짝 굽혀 균형을 잡되, 발은 코트에 고정하세요.",
    },
  },
  "forehand_drive": {
    "peak_wrist_above_shoulder": {
      "pass": "몸 앞에서 잘 잡아 치고 있어요.",
      "minor_fail": "조금만 더 일찍, 몸 앞에서 잡으면 타구가 빨라져요.",
      "major_fail": "타점이 늦어 셔틀콕이 옆으로 빠지고 있어요. 몸 앞 어깨~가슴 높이에서 일찍 잡으세요.",
    },
    "elbow_extension_>=160deg": {
      "pass": "전완 회내로 잘 때리고 있어요.",
      "minor_fail": "전완 회내를 조금 더 빠르게 해 라켓 면을 채 주세요.",
      "major_fail": "크게 휘두르지 말고 팔꿈치를 앞으로 내밀며 전완 회내로 짧고 빠르게 때리세요.",
    },
    "hip_rotation_>=20deg": {
      "pass": "골반·몸통 회전을 잘 활용하고 있어요.",
      "minor_fail": "골반을 조금 더 돌려 주면 드라이브가 묵직해져요.",
      "major_fail": "상체 회전이 거의 없어요. 임팩트 직전 골반을 앞으로 돌려 그 힘을 실으세요.",
    },
    "knees_bent_at_prep": {
      "pass": "낮고 균형 잡힌 자세로 잘 치고 있어요.",
      "minor_fail": "무릎을 살짝 더 굽혀 낮은 자세를 유지하면 연속 드라이브가 안정돼요.",
      "major_fail": "스탠스가 높아요. 무릎을 굽힌 낮은 자세에서 셔틀콕 쪽으로 한 걸음 디디며 치세요.",
    },
  },
}

# Speed/step star buckets WITH variants (coaching_knowledge.json doesn't cover these).
# Only 1,2,4,5 are surfaced (3 = average → not shown). high_clear: speed+step;
# forehand_drive: speed only; short_serve: neither (dropped by axis filter).
SPEED_STEP = {
  "high_clear": {
    "speed": {
      "1": ["스윙 속도가 평균보다 많이 느려요. 임팩트 직전 손목 스냅을 빠르게 채 주세요.",
            "스윙이 많이 느려요. 임팩트 순간 손목을 빠르게 터뜨려 라켓 헤드 속도를 올리세요."],
      "2": ["스윙 속도가 살짝 느려요. 임팩트 직전 가속을 의식해 보세요.",
            "조금만 더 빠르게. 임팩트 직전에 가속하는 느낌을 살려 보세요."],
      "3": ["평균적인 스윙 속도예요."],
      "4": ["스윙 속도가 좋아요. 이 리듬을 유지하세요.", "빠른 스윙이에요. 지금 템포 좋습니다."],
      "5": ["스윙이 아주 빨라요. 컨트롤만 유지하면 강력한 클리어가 나와요.",
            "스윙 속도가 매우 빨라요. 정확도만 잡으면 위력적이에요."],
    },
    "step": {
      "1": ["발이 거의 멈춰 있어요. 셔틀콕 아래로 들어가는 풋워크와 시저스킥을 연습해 보세요.",
            "이동이 거의 없어요. 셔틀콕 아래로 들어갔다 빠지는 풋워크를 연습하세요."],
      "2": ["풋워크가 조금 부족해요. 타구 후 빠르게 제자리로 돌아오는 스텝을 더해 보세요.",
            "스텝을 조금 더. 친 뒤 중앙으로 복귀하는 리커버리를 의식하세요."],
      "3": ["평균적인 풋워크예요."],
      "4": ["활발한 풋워크예요.", "발 움직임이 활발해요. 좋습니다."],
      "5": ["매우 활발한 풋워크예요. 좋습니다.", "풋워크가 아주 부지런해요."],
    },
  },
  "forehand_drive": {
    "speed": {
      "1": ["드라이브 스윙이 많이 느려요. 임팩트 직전 팔뚝 회내와 손목 스냅으로 라켓 속도를 끌어올리세요.",
            "스윙이 많이 느려요. 짧고 빠른 전완 회내로 라켓을 채 주세요."],
      "2": ["스윙이 살짝 느려요. 짧고 빠른 스냅을 의식하세요.",
            "조금만 더 빠르게, 컴팩트한 스냅으로 때리세요."],
      "3": ["평균적인 드라이브 속도예요."],
      "4": ["드라이브 속도가 좋아요.", "빠른 드라이브예요. 좋습니다."],
      "5": ["아주 빠른 드라이브예요. 컨트롤만 유지하면 위협적이에요.",
            "드라이브가 매우 빨라요. 정확도만 잡으면 위협적이에요."],
    },
  },
}


def _dedup(seq):
    out = []
    for x in seq:
        x = (x or "").strip()
        if x and x not in out:
            out.append(x)
    return out


def main() -> int:
    ck = json.loads(CK.read_text(encoding="utf-8"))
    cur = json.loads(CUR.read_text(encoding="utf-8"))

    out = {
        "_doc": cur["_doc"],
        "_provenance": ("v1 sentences from data/coaching_knowledge.json (Session B); v2 "
                        "variants + speed/step from scripts/gen_rulebook_tips.py (Session C). "
                        "Each bucket is a LIST of interchangeable phrasings; selection picks "
                        "ONE per cell (seeded by clip) so two variants never co-occur."),
        "version": "rulebook-v3-variants",
        "severity_doc": cur["severity_doc"],
        "na_default": cur["na_default"],
        "all_good_default": cur["all_good_default"],
        "guardrails": cur["guardrails"],
        "strokes": {},
    }

    for st in STROKES:
        posture = {}
        for crit in CRITERIA:
            entry = ck[st][crit]
            v1 = {
                "pass": _clean_good(entry.get("good", "")),
                "minor_fail": (entry.get("fix_ko_minor") or entry.get("fix_ko", "")).strip(),
                "major_fail": entry.get("fix_ko", "").strip(),
            }
            v2 = POSTURE_V2.get(st, {}).get(crit, {})
            posture[crit] = {
                "applies": entry.get("applies", "yes"),
                "pass": _dedup([v1["pass"], v2.get("pass")]),
                "minor_fail": _dedup([v1["minor_fail"], v2.get("minor_fail")]),
                "major_fail": _dedup([v1["major_fail"], v2.get("major_fail")]),
            }
        out["strokes"][st] = {"posture": posture}
        for axis, buckets in SPEED_STEP.get(st, {}).items():
            out["strokes"][st][axis] = {k: _dedup(v) for k, v in buckets.items()}

    out["strokes"]["unknown_ood"] = cur["strokes"]["unknown_ood"]

    OUT.write_text(json.dumps(out, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    # report variant counts
    n2 = sum(1 for st in STROKES for c in CRITERIA for sev in ("pass", "minor_fail", "major_fail")
             if len(out["strokes"][st]["posture"][c][sev]) >= 2)
    print(f"[ok] wrote {OUT}")
    print(f"     posture cells with >=2 variants: {n2} / {len(STROKES)*len(CRITERIA)*3}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
