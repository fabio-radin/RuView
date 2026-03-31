"""
WiFi-DensePose Python v1 — Full Pipeline Benchmark
===================================================
Pipeline: preprocess_csi_data → extract_features → detect_human_presence
          (+ add_to_history for Doppler cache)

Reference data: v1/data/proof/sample_csi_data.json
  1 000 frames · 3 antennas · 56 subcarriers · 100 Hz

Usage (from RuView/):
    python v1/benchmarks/benchmark_v1.py
"""

import json
import statistics
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import numpy as np

# ── paths ──────────────────────────────────────────────────────────────────
V1_ROOT = Path(__file__).resolve().parent.parent        # …/RuView/v1/
SAMPLE_DATA = V1_ROOT / "data" / "proof" / "sample_csi_data.json"
OUT_JSON    = Path(__file__).resolve().parent / "v1_results.json"

sys.path.insert(0, str(V1_ROOT))

from src.hardware.csi_extractor import CSIData           # noqa: E402
from src.core.csi_processor    import CSIProcessor       # noqa: E402

# ── configuration (mirrors sample data parameters) ──────────────────────────
CONFIG = {
    "sampling_rate"          : 100.0,   # Hz — matches sample_csi_data.json
    "window_size"            : 56,      # subcarriers
    "overlap"                : 0.5,
    "noise_threshold"        : -30.0,   # dB
    "human_detection_threshold": 0.8,
    "smoothing_factor"       : 0.9,
    "max_history_size"       : 500,
    "doppler_window"         : 64,
    "enable_preprocessing"   : True,
    "enable_feature_extraction": True,
    "enable_human_detection" : True,
}

WARMUP  = 100   # frames discarded before measurement (warm up numpy caches)
MEASURE = 1000  # frames to time


# ── helpers ─────────────────────────────────────────────────────────────────

def load_frames(path: Path) -> list:
    """Load all frames from the reference CSI JSON file."""
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)

    freq = data["frequency_hz"]
    bw   = data["bandwidth_hz"]
    n_sc = data["num_subcarriers"]
    n_ant= data["num_antennas"]

    frames = []
    for fr in data["frames"]:
        frames.append(CSIData(
            timestamp      = datetime.now(timezone.utc),
            amplitude      = np.array(fr["amplitude"], dtype=np.float64),
            phase          = np.array(fr["phase"],     dtype=np.float64),
            frequency      = freq,
            bandwidth      = bw,
            num_subcarriers= n_sc,
            num_antennas   = n_ant,
            snr            = 25.0,
            metadata       = {},
        ))
    return frames


def run_full_pipeline(processor: CSIProcessor, frame: CSIData):
    """Single-frame full pipeline (synchronous, no async overhead)."""
    preprocessed = processor.preprocess_csi_data(frame)
    features     = processor.extract_features(preprocessed)
    result       = processor.detect_human_presence(features)
    processor.add_to_history(frame)          # builds Doppler cache
    return result


def percentile(sorted_data: list, p: float) -> float:
    idx = min(int(p * len(sorted_data)), len(sorted_data) - 1)
    return sorted_data[idx]


# ── main ────────────────────────────────────────────────────────────────────

def main():
    print("=" * 60)
    print("  WiFi-DensePose Python v1 -- Full Pipeline Benchmark")
    print("=" * 60)

    # Load reference data
    print(f"\nLoading frames from {SAMPLE_DATA.relative_to(V1_ROOT.parent)} ...")
    frames = load_frames(SAMPLE_DATA)
    print(f"  {len(frames)} frames · {frames[0].num_antennas} antennas "
          f"· {frames[0].num_subcarriers} subcarriers · {CONFIG['sampling_rate']:.0f} Hz")

    processor = CSIProcessor(CONFIG)

    # ── warm-up ─────────────────────────────────────────────────────────────
    print(f"\nWarm-up ({WARMUP} frames) ...", end=" ", flush=True)
    for i in range(WARMUP):
        run_full_pipeline(processor, frames[i % len(frames)])
    processor.clear_history()
    processor.reset_statistics()
    print("done")

    # ── measurement ─────────────────────────────────────────────────────────
    n = min(MEASURE, len(frames))
    timings_ns: list[int] = []

    print(f"Measuring  ({n} frames) ...", end=" ", flush=True)
    for i in range(n):
        t0 = time.perf_counter_ns()
        run_full_pipeline(processor, frames[i % len(frames)])
        t1 = time.perf_counter_ns()
        timings_ns.append(t1 - t0)
    print("done\n")

    # ── statistics ──────────────────────────────────────────────────────────
    timings_us = sorted(t / 1_000 for t in timings_ns)
    mean_us    = statistics.mean(timings_us)
    median_us  = statistics.median(timings_us)
    p95_us     = percentile(timings_us, 0.95)
    p99_us     = percentile(timings_us, 0.99)
    min_us     = timings_us[0]
    max_us     = timings_us[-1]
    fps        = 1_000_000 / mean_us

    print("Pipeline stages timed:")
    print("  preprocess_csi_data -> extract_features -> detect_human_presence\n")
    print(f"  {'Frames measured':<20}: {n}")
    print(f"  {'Mean':<20}: {mean_us:>10.1f} us  ({mean_us/1000:.3f} ms)")
    print(f"  {'Median':<20}: {median_us:>10.1f} us")
    print(f"  {'Min':<20}: {min_us:>10.1f} us")
    print(f"  {'p95':<20}: {p95_us:>10.1f} us")
    print(f"  {'p99':<20}: {p99_us:>10.1f} us")
    print(f"  {'Max':<20}: {max_us:>10.1f} us")
    print(f"  {'Throughput':<20}: {fps:>10.0f} fps")

    # ── save JSON for comparison script ─────────────────────────────────────
    result = {
        "language"  : "Python v1",
        "pipeline"  : "preprocess -> extract_features -> detect_human_presence",
        "frames"    : n,
        "mean_us"   : mean_us,
        "median_us" : median_us,
        "p95_us"    : p95_us,
        "p99_us"    : p99_us,
        "min_us"    : min_us,
        "max_us"    : max_us,
        "fps"       : fps,
    }
    OUT_JSON.parent.mkdir(parents=True, exist_ok=True)
    with open(OUT_JSON, "w", encoding="utf-8") as fh:
        json.dump(result, fh, indent=2)
    print(f"\n[results saved -> {OUT_JSON.relative_to(V1_ROOT.parent)}]")


if __name__ == "__main__":
    main()
