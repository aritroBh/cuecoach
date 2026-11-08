#!/usr/bin/env python3
"""Extract unlabeled review frames from local videos in tools/footage."""

from __future__ import annotations

import argparse
import csv
import re
from pathlib import Path

import cv2


ROOT = Path(__file__).resolve().parents[2]
DEFAULT_SOURCE = ROOT / "tools" / "footage"
DEFAULT_OUTPUT = Path(__file__).parent / "data" / "footage_frames"
DATA_ROOT = (Path(__file__).parent / "data").resolve()
VIDEO_SUFFIXES = {".mov", ".mp4", ".m4v", ".avi", ".mkv"}


def extract_frames(source: Path, output: Path, every_n_frames: int = 15, max_frames: int | None = None) -> int:
    if every_n_frames < 1 or (max_frames is not None and max_frames < 1):
        raise ValueError("frame interval and max-frames must be positive")
    source = source.resolve()
    videos = [source] if source.is_file() else sorted(path for path in source.rglob("*") if path.suffix.lower() in VIDEO_SUFFIXES)
    if not videos or any(not video.is_file() for video in videos):
        raise FileNotFoundError(f"no supported video files found under {source}")
    output = output.resolve()
    if output != DATA_ROOT and DATA_ROOT not in output.parents:
        raise ValueError(f"output must stay under {DATA_ROOT}")
    if output.exists() and any(output.iterdir()):
        raise FileExistsError(f"{output} is not empty; choose a new output path")
    output.mkdir(parents=True, exist_ok=True)
    rows: list[tuple[str, int, float, str]] = []
    count = 0
    for video_index, video in enumerate(videos):
        capture = cv2.VideoCapture(str(video))
        if not capture.isOpened():
            capture.release()
            raise OSError(f"could not open video {video}")
        fps = float(capture.get(cv2.CAP_PROP_FPS))
        if fps <= 0:
            capture.release()
            raise ValueError(f"video has an invalid frame rate: {video}")
        stem = re.sub(r"[^A-Za-z0-9_-]+", "_", video.stem).strip("_") or "clip"
        frame_index = 0
        saved_from_video = 0
        while True:
            ok, frame = capture.read()
            if not ok:
                break
            if frame_index % every_n_frames == 0:
                filename = f"{video_index:02d}_{stem}_{frame_index:08d}.jpg"
                if not cv2.imwrite(str(output / filename), frame, [cv2.IMWRITE_JPEG_QUALITY, 94]):
                    capture.release()
                    raise OSError(f"failed to write {output / filename}")
                rows.append((str(video), frame_index, round(frame_index / fps, 3), filename))
                count += 1
                saved_from_video += 1
                if max_frames is not None and saved_from_video >= max_frames:
                    break
            frame_index += 1
        capture.release()
    with (output / "manifest.csv").open("w", newline="") as manifest:
        writer = csv.writer(manifest)
        writer.writerow(("source", "frame_index", "timestamp_seconds", "image"))
        writer.writerows(rows)
    return count


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    parser.add_argument("--out", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--every-n-frames", type=int, default=15)
    parser.add_argument("--max-frames-per-video", type=int)
    args = parser.parse_args()
    count = extract_frames(args.source, args.out, args.every_n_frames, args.max_frames_per_video)
    print(f"Extracted {count} unlabeled frames to {args.out}")


if __name__ == "__main__":
    main()
