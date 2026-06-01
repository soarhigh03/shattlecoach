"""Session A · baseline evaluation. Runs the current V4 pipeline on the held-out
test split and summarizes per-clip results (stroke pred, OOD flag, stars, tips).

Produces:
  experiments/demo_v4/output/baseline_eval.json   raw per-clip rows
  reports/BASELINE_EVAL.html                       human-readable summary

This measures CURRENT behavior (classifier + OOD still active) so we have a
before/after baseline against the point-5 change (user picks stroke).

Usage:  PYTHONIOENCODING=utf-8 .venv/Scripts/python.exe scripts/baseline_eval.py
"""
from __future__ import annotations
import json, subprocess, sys, time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CLIPS = ROOT / "data" / "donghwi_clips"
OUT = ROOT / "experiments" / "demo_v4" / "output"
QUICK = ROOT / "scripts" / "quick_demo.py"
PY = sys.executable


def run_clip(clip: Path) -> dict:
    t0 = time.perf_counter()
    proc = subprocess.run([PY, str(QUICK), "--video", str(clip)],
                          capture_output=True, text=True, encoding="utf-8", errors="replace")
    secs = time.perf_counter() - t0
    jp = OUT / f"{clip.stem}_score.json"
    row = {"clip": clip.name, "seconds": round(secs, 1), "ok": jp.exists()}
    if proc.returncode != 0:
        row["error"] = (proc.stderr or proc.stdout or "")[-300:]
    if jp.exists():
        d = json.loads(jp.read_text(encoding="utf-8"))
        stroke = d.get("stroke") or {}
        if isinstance(stroke, str):
            stroke = {"label": stroke}
        row.update({
            "pred": stroke.get("label"),
            "conf": stroke.get("top1_confidence"),
            "is_ood": stroke.get("is_ood"),
            "det_rate": d.get("pose_detection_rate"),
            "axes_evaluated": d.get("axes_evaluated"),
            "posture_stars": d.get("posture_stars"),
            "speed_stars": d.get("speed_stars"),
            "step_stars": d.get("step_stars"),
            "tips": [t.get("tip_ko") for t in d.get("coaching_tips", [])],
            "has_annotation": bool(d.get("annotated_impact_png_base64")),
            "annotation_skip": d.get("annotation_skip_reason"),
        })
    return row


def main() -> int:
    split = json.loads((CLIPS / "split.json").read_text(encoding="utf-8"))
    test = []
    for stroke, names in split["test"].items():
        for n in names:
            test.append((stroke, n))
    print(f"[baseline] {len(test)} held-out test clips")
    rows = []
    for i, (true_stroke, name) in enumerate(test, 1):
        clip = CLIPS / name
        r = run_clip(clip)
        r["true_stroke"] = true_stroke
        rows.append(r)
        print(f"  [{i:2d}/{len(test)}] {name:34s} pred={r.get('pred')!s:14s} ood={r.get('is_ood')} "
              f"posture={r.get('posture_stars')} ({r['seconds']}s)")
    (OUT / "baseline_eval.json").write_text(json.dumps(rows, indent=2, ensure_ascii=False), encoding="utf-8")

    # aggregate
    n = len(rows)
    ood_n = sum(1 for r in rows if r.get("is_ood"))
    det_fail = sum(1 for r in rows if (r.get("det_rate") or 0) < 0.5)
    correct = sum(1 for r in rows if r.get("pred") == r.get("true_stroke"))
    by = {}
    for r in rows:
        by.setdefault(r["true_stroke"], {"n": 0, "ood": 0, "correct": 0})
        b = by[r["true_stroke"]]; b["n"] += 1
        b["ood"] += int(bool(r.get("is_ood")))
        b["correct"] += int(r.get("pred") == r["true_stroke"])

    rows_html = "\n".join(
        f"<tr><td>{r['clip']}</td><td>{r['true_stroke']}</td>"
        f"<td class='{'bad' if r.get('pred')!=r['true_stroke'] else 'ok'}'>{r.get('pred')}</td>"
        f"<td class='c'>{'OOD' if r.get('is_ood') else '-'}</td>"
        f"<td class='c'>{r.get('det_rate')}</td>"
        f"<td class='c'>{r.get('posture_stars')}/{r.get('speed_stars')}/{r.get('step_stars')}</td>"
        f"<td>{'; '.join(r.get('tips') or [])}</td></tr>"
        for r in rows)
    by_html = "\n".join(
        f"<tr><td>{k}</td><td class='c'>{v['n']}</td><td class='c'>{v['ood']} ({100*v['ood']//max(v['n'],1)}%)</td>"
        f"<td class='c'>{v['correct']}/{v['n']}</td></tr>" for k, v in by.items())

    html = f"""<!DOCTYPE html><html lang="ko"><head><meta charset="UTF-8">
<title>ShattleCoach Baseline Eval</title><style>
body{{background:#0f1419;color:#e6edf3;font-family:'Malgun Gothic',sans-serif;max-width:1100px;margin:0 auto;padding:30px}}
h1{{font-size:23px}} .mut{{color:#9aa7b4}}
table{{width:100%;border-collapse:collapse;margin:14px 0;font-size:13px}}
th,td{{border:1px solid #2d3946;padding:7px 9px}} th{{background:#222c38}}
td.c{{text-align:center}} .bad{{color:#f85149;font-weight:700}} .ok{{color:#3fb950}}
.kpi{{display:inline-block;background:#1a212b;border:1px solid #2d3946;border-radius:10px;padding:12px 18px;margin:6px}}
.kpi b{{font-size:22px;color:#4ea1ff}}
.box{{background:rgba(248,81,73,.08);border:1px solid rgba(248,81,73,.35);border-radius:8px;padding:12px 16px;margin:14px 0}}
</style></head><body>
<h1>Baseline Evaluation — held-out test set (현재 분류기+OOD 활성 상태)</h1>
<div class="mut">point-5(사용자 stroke 선택) 적용 전 기준점. 생성: baseline_eval.py</div>
<div>
  <span class="kpi">clips <b>{n}</b></span>
  <span class="kpi">OOD 처리 <b>{ood_n}</b> ({100*ood_n//max(n,1)}%)</span>
  <span class="kpi">분류 정답 <b>{correct}/{n}</b></span>
  <span class="kpi">검출 실패(&lt;50%) <b>{det_fail}</b></span>
</div>
<div class="box"><b>해석:</b> OOD 비율이 높다면 = 실제 폰 클립이 학습분포(BST 방송영상) 밖이라는 뜻 →
분류기/OOD를 신뢰할 수 없음 → <b>point-5(사용자가 stroke 직접 선택)로 분류기 우회</b>가 정당화됨.</div>
<h3>클래스별</h3>
<table><tr><th>true stroke</th><th>n</th><th>OOD</th><th>분류 정답</th></tr>{by_html}</table>
<h3>클립별 상세</h3>
<table><tr><th>clip</th><th>true</th><th>pred</th><th>OOD</th><th>det</th><th>자세/속도/스텝</th><th>tips</th></tr>{rows_html}</table>
</body></html>"""
    (ROOT / "reports" / "BASELINE_EVAL.html").write_text(html, encoding="utf-8")
    print(f"\n[ok] {n} clips | OOD {ood_n} ({100*ood_n//max(n,1)}%) | classify-correct {correct}/{n} | det-fail {det_fail}")
    print(f"[ok] reports/BASELINE_EVAL.html")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
