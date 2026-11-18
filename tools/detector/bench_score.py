#!/usr/bin/env python3
"""Score the D32 virtual-sim detector benchmark (results from CueCoachTests/DetectorBenchTests).

    uv run python bench_score.py --bench data/bench/v1 [--markdown out.md]

Matching is on the table, in metres: a detection matches the nearest unmatched ground-truth ball within one ball
diameter (greedy, closest pairs first). Ground truth with visibility >= 0.5 is *required* (counts for recall);
0 < visibility < 0.5 is *optional* (matching it is neither a hit nor a false positive); everything else unmatched
is a false positive.

Selection metric (fixed before measuring): identity F1 = harmonic mean of
  identity recall    = required balls found AND named correctly (cue, 1–15) / required balls
  identity precision = detections that are a correctly named ball / all detections (optional matches excluded).
It rewards finding balls, naming them, and not inventing any, in one number. Latency is reported as relative only.
"""

from __future__ import annotations

import argparse
import json
from collections import defaultdict
from pathlib import Path

import numpy as np

BALL_D = 0.05715
KIND_OF = {0: "cue", 8: "eight", **{n: "solid" for n in range(1, 8)}, **{n: "stripe" for n in range(9, 16)}}


def match(truth: list[dict], dets: list[dict], radius: float = BALL_D) -> list[tuple[int, int, float]]:
    """Greedy nearest pairs (truth index, detection index, distance m) within `radius`."""
    pairs = []
    for i, t in enumerate(truth):
        for j, d in enumerate(dets):
            dist = float(np.hypot(t["x"] - d["x"], t["y"] - d["y"]))
            if dist <= radius:
                pairs.append((dist, i, j))
    pairs.sort()
    used_t, used_d, out = set(), set(), []
    for dist, i, j in pairs:
        if i in used_t or j in used_d:
            continue
        used_t.add(i)
        used_d.add(j)
        out.append((i, j, dist))
    return out


def det_number(d: dict) -> int | None:
    """Detector's ball identity: 0 = cue, 1–15, or None (no number claimed)."""
    if d["kind"] == "cue":
        return 0
    if d["kind"] == "eight":
        return 8
    n = d.get("number", -1)
    return n if isinstance(n, int) and 1 <= n <= 15 else None


def f1(p: float, r: float) -> float:
    return 0.0 if p + r == 0 else 2 * p * r / (p + r)


class Tally:
    def __init__(self):
        self.req = self.found = self.id_ok = self.group_ok = self.wrong_id = self.dets = self.fp = self.opt = 0
        self.err: list[float] = []

    def add(self, truth: list[dict], dets: list[dict]) -> None:
        required = [t["visible"] >= 0.5 and t["image"] is not None for t in truth]
        self.req += sum(required)
        self.dets += len(dets)
        matched_d = set()
        for i, j, dist in match(truth, dets):
            matched_d.add(j)
            if not required[i]:
                self.opt += 1
                continue
            self.found += 1
            self.err.append(dist)
            n_true, n_det = truth[i]["number"], det_number(dets[j])
            if n_det == n_true:
                self.id_ok += 1
            elif n_det is not None:
                self.wrong_id += 1
            if dets[j]["kind"] == KIND_OF[n_true]:
                self.group_ok += 1
        self.fp += len(dets) - len(matched_d)

    def row(self) -> dict:
        scored = max(self.dets - self.opt, 1)
        recall = self.found / max(self.req, 1)
        precision = self.found / max(self.found + self.fp, 1)
        id_recall = self.id_ok / max(self.req, 1)
        id_precision = self.id_ok / scored
        err = np.array(self.err) * 100 if self.err else np.array([np.nan])
        return {"required": self.req, "recall": recall, "precision": precision, "f1": f1(precision, recall),
                "id_recall": id_recall, "id_precision": id_precision, "id_f1": f1(id_precision, id_recall),
                "id_acc_found": self.id_ok / max(self.found, 1), "group_acc_found": self.group_ok / max(self.found, 1),
                "wrong_id_rate": self.wrong_id / max(self.found, 1), "fp": self.fp,
                "loc_med_cm": float(np.nanmedian(err)), "loc_p90_cm": float(np.nanpercentile(err, 90))}


def bins(f: dict) -> dict[str, str]:
    el, dist = f["elevation_deg"], f["distance_m"]
    out = {
        "elevation": "20–32°" if el < 32 else "32–45°" if el < 45 else "45–60°" if el < 60 else "60–80°",
        "distance": "1–2 m" if dist < 2 else "2–3 m" if dist < 3 else "3–4 m",
        "layout": f["layout"],
        "occluders": "hand+cue" if f["occluders"] else "none",
        "motion": "moving balls" if f["moving"] else ("camera shake" if f["shake_px"] >= 6 else "still"),
        "glare": "flare/sheen" if f.get("flare") else "none",
        "exposure": "dark" if f["ev"] < -0.4 else "bright" if f["ev"] > 0.4 else "normal",
    }
    return out


def score(bench: Path, results_dir: Path | None = None) -> dict:
    manifest = json.loads((bench / "manifest.json").read_text())
    truth = {r["file"]: r for r in manifest["frames"]}
    results = {}
    for path in sorted((results_dir or bench / "results").glob("*.json")):
        res = json.loads(path.read_text())
        total, by_ball = Tally(), defaultdict(Tally)
        by_factor: dict[str, dict[str, Tally]] = defaultdict(lambda: defaultdict(Tally))
        empty_fp, empty_frames, ms = 0, 0, []
        for fr in res["frames"]:
            gt = truth[fr["file"]]
            dets = fr["detections"]
            ms.append(fr["ms"])
            if gt["factors"]["empty"]:
                empty_frames += 1
                empty_fp += len(dets)
                total.add([], dets)
                continue
            total.add(gt["balls"], dets)
            for k, v in bins(gt["factors"]).items():
                by_factor[k][v].add(gt["balls"], dets)
            for t in gt["balls"]:
                # Per-ball recall: that ball alone vs every detection (so other balls don't count as FPs).
                by_ball[t["number"]].add([t], [d for d in dets if np.hypot(d["x"] - t["x"], d["y"] - t["y"]) <= BALL_D])
        clip = Tally()
        for c in res.get("clips", []):
            gt = truth[c["lastFile"]]
            clip.add(gt["balls"], c["tracks"])
        ms_a = np.array(ms)
        results[res["candidate"]] = {
            "platform": res.get("platform"), "frames": len(ms), "overall": total.row(), "tracker": clip.row(),
            "empty_fp_per_frame": empty_fp / max(empty_frames, 1), "empty_frames": empty_frames,
            "ms_mean": float(ms_a.mean()), "ms_p50": float(np.median(ms_a)), "ms_p95": float(np.percentile(ms_a, 95)),
            "by_ball": {n: t.row() for n, t in sorted(by_ball.items())},
            "by_factor": {k: {v: t.row() for v, t in sorted(d.items())} for k, d in by_factor.items()},
        }
    return results


def markdown(results: dict) -> str:
    names = list(results)
    pct = lambda x: f"{100 * x:.1f}%"
    lines = ["| metric | " + " | ".join(names) + " |", "|---|" + "---|" * len(names)]
    rows = [
        ("**identity F1 (selection metric)**", lambda r: f"**{pct(r['overall']['id_f1'])}**"),
        ("detection recall (vis ≥ 50%)", lambda r: pct(r["overall"]["recall"])),
        ("detection precision", lambda r: pct(r["overall"]["precision"])),
        ("detection F1", lambda r: pct(r["overall"]["f1"])),
        ("exact identity, of found balls", lambda r: pct(r["overall"]["id_acc_found"])),
        ("group (cue/8/solid/stripe), of found", lambda r: pct(r["overall"]["group_acc_found"])),
        ("wrong number claimed, of found", lambda r: pct(r["overall"]["wrong_id_rate"])),
        ("localisation median / p90 (cm)", lambda r: f"{r['overall']['loc_med_cm']:.2f} / {r['overall']['loc_p90_cm']:.2f}"),
        ("false positives, all frames", lambda r: str(r["overall"]["fp"])),
        ("false positives per empty-cloth frame", lambda r: f"{r['empty_fp_per_frame']:.2f}"),
        ("tracker (1 s clip) identity F1", lambda r: pct(r["tracker"]["id_f1"])),
        ("tracker recall / precision", lambda r: f"{pct(r['tracker']['recall'])} / {pct(r['tracker']['precision'])}"),
        ("latency mean / p95 (ms, simulator, relative)", lambda r: f"{r['ms_mean']:.1f} / {r['ms_p95']:.1f}"),
    ]
    for label, fn in rows:
        lines.append(f"| {label} | " + " | ".join(fn(results[n]) for n in names) + " |")
    out = ["\n".join(lines), ""]
    first = results[names[0]]
    for factor in first["by_factor"]:
        out.append(f"\n**Identity F1 / recall by {factor}**\n")
        vals = list(first["by_factor"][factor])
        out.append("| " + factor + " | n balls | " + " | ".join(names) + " |")
        out.append("|---|---|" + "---|" * len(names))
        for v in vals:
            cells = []
            for n in names:
                r = results[n]["by_factor"][factor].get(v)
                cells.append(f"{pct(r['id_f1'])} / {pct(r['recall'])}" if r else "–")
            out.append(f"| {v} | {first['by_factor'][factor][v]['required']} | " + " | ".join(cells) + " |")
    out.append("\n**Per ball: recall / exact identity of found**\n")
    out.append("| ball | " + " | ".join(names) + " |")
    out.append("|---|" + "---|" * len(names))
    for b in sorted(first["by_ball"], key=int):
        label = "cue" if int(b) == 0 else str(b)
        out.append(f"| {label} | " + " | ".join(
            f"{pct(results[n]['by_ball'][b]['recall'])} / {pct(results[n]['by_ball'][b]['id_acc_found'])}" for n in names) + " |")
    return "\n".join(out) + "\n"


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--bench", type=Path, default=Path(__file__).parent / "data" / "bench" / "v1")
    p.add_argument("--results", type=Path, help="results directory (default <bench>/results)")
    p.add_argument("--markdown", type=Path)
    p.add_argument("--json", type=Path)
    a = p.parse_args()
    results = score(a.bench, a.results)
    md = markdown(results)
    print(md)
    if a.markdown:
        a.markdown.write_text(md)
    if a.json:
        a.json.write_text(json.dumps(results, indent=1, default=str))


if __name__ == "__main__":
    main()
