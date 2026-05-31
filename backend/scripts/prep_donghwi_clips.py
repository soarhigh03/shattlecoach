"""Session A · step 1-2. Normalize raw clips + build a reproducible train/test split.

Source:  C:/dev/shattlecock/video/   files like "drive (1).mp4", "highclear (3).mp4", "serve (12).mp4"
Maps:    drive->forehand_drive, highclear->high_clear, serve->short_serve
Output:  data/donghwi_clips/{player}_{stroke}_{idx:03d}.mp4  (copies; originals untouched)
         data/donghwi_clips/split.json  (dev = calibration subset, test = held-out)

Clips are intentionally good-form (per user), so dev clips may anchor the "good" side
of thresholds — but thresholds' ground truth is coaching knowledge, not these clips.

Usage:  .venv/Scripts/python.exe scripts/prep_donghwi_clips.py
"""
from __future__ import annotations
import json, re, shutil, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "video"
DST = ROOT / "data" / "donghwi_clips"
PLAYER = "donghwi"

PREFIX_TO_STROKE = {
    "drive": "forehand_drive",
    "highclear": "high_clear",
    "serve": "short_serve",
}
# how many clips per class go into the calibration/dev subset (rest = held-out test)
DEV_N = {"forehand_drive": 5, "high_clear": 6, "short_serve": 5}

NAME_RE = re.compile(r"^(drive|highclear|serve)\s*\((\d+)\)\.mp4$", re.IGNORECASE)


def even_spread(indices: list[int], k: int) -> list[int]:
    """Pick k evenly-spread items from a sorted list (reproducible)."""
    if k >= len(indices):
        return list(indices)
    return [indices[round(i * (len(indices) - 1) / (k - 1))] for i in range(k)] if k > 1 else [indices[0]]


def main() -> int:
    if not SRC.exists():
        print(f"ERROR: source {SRC} not found")
        return 2
    DST.mkdir(parents=True, exist_ok=True)

    # discover + map
    by_stroke: dict[str, list[tuple[int, Path]]] = {s: [] for s in PREFIX_TO_STROKE.values()}
    skipped = []
    for p in sorted(SRC.glob("*.mp4")):
        m = NAME_RE.match(p.name)
        if not m:
            skipped.append(p.name)
            continue
        prefix, n = m.group(1).lower(), int(m.group(2))
        stroke = PREFIX_TO_STROKE[prefix]
        by_stroke[stroke].append((n, p))

    if skipped:
        print(f"[warn] {len(skipped)} files didn't match pattern: {skipped[:5]}")

    split = {"_doc": "dev = calibration subset (you MAY look at these while tuning); "
                      "test = held-out (do NOT look at these while tuning). "
                      "Clips are intentionally good-form. Maps drive->forehand_drive, "
                      "highclear->high_clear, serve->short_serve.",
             "player": PLAYER, "dev": {}, "test": {}, "counts": {}}

    total_copied = 0
    for stroke, items in by_stroke.items():
        items.sort(key=lambda x: x[0])
        idxs = [n for n, _ in items]
        # copy with normalized names (preserve original index)
        norm_names = {}
        for n, src in items:
            dstname = f"{PLAYER}_{stroke}_{n:03d}.mp4"
            shutil.copy2(src, DST / dstname)
            norm_names[n] = dstname
            total_copied += 1
        dev_idx = set(even_spread(idxs, DEV_N.get(stroke, max(1, len(idxs) // 3))))
        split["dev"][stroke] = [norm_names[n] for n in idxs if n in dev_idx]
        split["test"][stroke] = [norm_names[n] for n in idxs if n not in dev_idx]
        split["counts"][stroke] = {"total": len(idxs),
                                   "dev": len(split["dev"][stroke]),
                                   "test": len(split["test"][stroke])}
        print(f"  {stroke:16s} total={len(idxs):2d}  dev={len(split['dev'][stroke])}  test={len(split['test'][stroke])}")

    (DST / "split.json").write_text(json.dumps(split, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"[ok] copied {total_copied} clips -> {DST}")
    print(f"[ok] split.json written")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
