//! WiFi-DensePose Rust v2 — Full Pipeline Benchmark
//!
//! Pipeline: preprocess → sanitize_phase → extract_with_history → detect_human
//!
//! Synthetic data dimensions match sample_csi_data.json:
//!   3 antennas × 56 subcarriers · 100 Hz · 5-path multipath model
//!
//! Usage (from wifi-densepose-rs/):
//!   cargo bench -p wifi-densepose-signal --bench full_pipeline_bench

use criterion::{criterion_group, criterion_main, BenchmarkId, Criterion, Throughput};
use ndarray::Array2;
use std::f64::consts::PI;
use wifi_densepose_signal::{
    CsiData, CsiProcessor, CsiProcessorConfig, FeatureExtractor, FeatureExtractorConfig,
    MotionDetector, MotionDetectorConfig, PhaseSanitizer, PhaseSanitizerConfig,
};

// ── dimensions matching sample_csi_data.json ────────────────────────────────
const NUM_ANTENNAS   : usize = 3;
const NUM_SUBCARRIERS: usize = 56;
const SAMPLING_RATE  : f64   = 100.0;   // Hz
const FREQ_CENTER    : f64   = 5.21e9;  // Hz (WiFi ch 42)
const BANDWIDTH      : f64   = 17.5e6;  // Hz
const HISTORY_LEN    : usize = 64;      // frames for Doppler estimation

// ── multipath model (same as generate_reference_signal.py) ──────────────────
const PATH_DELAYS : [f64; 5] = [0.0, 15e-9, 42e-9, 78e-9, 120e-9]; // seconds
const PATH_AMPS   : [f64; 5] = [1.0, 0.6,   0.35,  0.18,  0.08 ];

/// Wrap angle to [−π, π] (required by PhaseSanitizer).
#[inline]
fn wrap_to_pi(x: f64) -> f64 {
    let mut p = x % (2.0 * PI);
    if p >  PI { p -= 2.0 * PI; }
    if p < -PI { p += 2.0 * PI; }
    p
}

/// Synthesise one CSI frame at time `t` (seconds).
fn make_frame(frame_idx: usize) -> CsiData {
    let t = frame_idx as f64 / SAMPLING_RATE;

    // Breathing (0.3 Hz, 2% depth) and walking (1.2 Hz, 8% depth) modulation.
    let breathing = 1.0 + 0.02 * (2.0 * PI * 0.3 * t).sin();
    let walking   = 1.0 + 0.08 * (2.0 * PI * 1.2 * t).sin();

    let freq_spacing = BANDWIDTH / NUM_SUBCARRIERS as f64;

    let amplitude = Array2::from_shape_fn((NUM_ANTENNAS, NUM_SUBCARRIERS), |(a, k)| {
        let fk = FREQ_CENTER + (k as f64 - (NUM_SUBCARRIERS / 2) as f64) * freq_spacing;
        let mut amp = 0.0f64;
        for (p, (&delay, &pa)) in PATH_DELAYS.iter().zip(PATH_AMPS.iter()).enumerate() {
            amp += pa * (2.0 * PI * fk * delay + (a + p) as f64 * 0.5).cos();
        }
        amp.abs() * breathing * walking
    });

    let phase = Array2::from_shape_fn((NUM_ANTENNAS, NUM_SUBCARRIERS), |(a, k)| {
        let fk = FREQ_CENTER + (k as f64 - (NUM_SUBCARRIERS / 2) as f64) * freq_spacing;
        let mut ph = 0.0f64;
        for (p, &delay) in PATH_DELAYS.iter().enumerate() {
            ph += 2.0 * PI * fk * delay + (a + p) as f64 * 0.3;
        }
        wrap_to_pi(ph)
    });

    CsiData::builder()
        .amplitude(amplitude)
        .phase(phase)
        .frequency(FREQ_CENTER)
        .bandwidth(BANDWIDTH)
        .snr(25.0)
        .build()
        .expect("failed to build CsiData")
}

// ── benchmark: complete single-frame pipeline ────────────────────────────────

fn bench_full_pipeline(c: &mut Criterion) {
    let mut group = c.benchmark_group("full_pipeline");
    group.throughput(Throughput::Elements(1));

    // Pre-generate 1 000 frames and a fixed history buffer.
    let frames : Vec<CsiData> = (0..1000).map(make_frame).collect();
    let history: Vec<CsiData> = (0..HISTORY_LEN).map(make_frame).collect();

    group.bench_function("v2_rust_full_pipeline", |b| {
        // Construct processors once per benchmark run (not inside the hot loop).
        let csi_config = CsiProcessorConfig::builder()
            .sampling_rate(SAMPLING_RATE)
            .window_size(NUM_SUBCARRIERS)
            .overlap(0.5)
            .noise_threshold(-30.0)
            .enable_preprocessing(true)
            .enable_feature_extraction(true)
            .enable_human_detection(true)
            .build();

        let phase_config   = PhaseSanitizerConfig::default();
        let feature_config = FeatureExtractorConfig {
            fft_size           : 128,
            sampling_rate      : SAMPLING_RATE,
            min_doppler_history: 10,
            enable_doppler     : true,
        };

        let processor  = CsiProcessor::new(csi_config).expect("CsiProcessor::new");
        let mut sanitizer = PhaseSanitizer::new(phase_config).expect("PhaseSanitizer::new");
        let extractor  = FeatureExtractor::new(feature_config);
        let mut detector = MotionDetector::new(MotionDetectorConfig::default());

        let mut i = 0usize;
        b.iter(|| {
            let frame = &frames[i % frames.len()];
            i += 1;

            // Stage 1 — preprocess (noise removal, Hamming window, normalisation)
            let preprocessed = processor.preprocess(frame)
                .expect("preprocess");

            // Stage 2 — phase sanitisation (unwrap, outlier removal, smoothing)
            let clean_phase = sanitizer.sanitize_phase(&preprocessed.phase)
                .expect("sanitize_phase");

            let clean_frame = CsiData::builder()
                .amplitude(preprocessed.amplitude.clone())
                .phase(clean_phase)
                .frequency(preprocessed.frequency)
                .bandwidth(preprocessed.bandwidth)
                .snr(preprocessed.snr)
                .build()
                .expect("rebuild CsiData");

            // Stage 3 — feature extraction (amplitude, phase, correlation,
            //           Doppler FFT, PSD)
            let features = extractor.extract_with_history(&clean_frame, &history);

            // Stage 4 — human detection (motion analysis, confidence, smoothing)
            let result = detector.detect_human(&features);

            std::hint::black_box(result)
        });
    });

    group.finish();
}

// ── benchmark: individual stages (for breakdown comparison) ─────────────────

fn bench_pipeline_stages(c: &mut Criterion) {
    let mut group = c.benchmark_group("pipeline_stages");
    group.throughput(Throughput::Elements(1));

    let frame   = make_frame(42);
    let history : Vec<CsiData> = (0..HISTORY_LEN).map(make_frame).collect();

    let processor  = CsiProcessor::new(CsiProcessorConfig::default()).unwrap();
    let mut sanitizer = PhaseSanitizer::new(PhaseSanitizerConfig::default()).unwrap();
    let extractor  = FeatureExtractor::default_config();
    let mut detector  = MotionDetector::default_config();

    group.bench_function("1_preprocess", |b| {
        b.iter(|| std::hint::black_box(processor.preprocess(&frame).unwrap()))
    });

    let preprocessed = processor.preprocess(&frame).unwrap();

    group.bench_function("2_phase_sanitize", |b| {
        b.iter(|| {
            std::hint::black_box(sanitizer.sanitize_phase(&preprocessed.phase).unwrap())
        })
    });

    let clean_phase = sanitizer.sanitize_phase(&preprocessed.phase).unwrap();
    let clean_frame = CsiData::builder()
        .amplitude(preprocessed.amplitude.clone())
        .phase(clean_phase)
        .frequency(preprocessed.frequency)
        .bandwidth(preprocessed.bandwidth)
        .snr(preprocessed.snr)
        .build()
        .unwrap();

    group.bench_function("3_feature_extract", |b| {
        b.iter(|| {
            std::hint::black_box(extractor.extract_with_history(&clean_frame, &history))
        })
    });

    let features = extractor.extract_with_history(&clean_frame, &history);

    group.bench_function("4_motion_detect", |b| {
        b.iter(|| std::hint::black_box(detector.detect_human(&features)))
    });

    group.finish();
}

// ── throughput sweep: 1 → 1 000 frames/batch ────────────────────────────────

fn bench_throughput_sweep(c: &mut Criterion) {
    let mut group = c.benchmark_group("throughput_sweep");

    for batch in [1usize, 10, 100, 1000] {
        let frames : Vec<CsiData> = (0..batch).map(make_frame).collect();
        let history: Vec<CsiData> = (0..HISTORY_LEN).map(make_frame).collect();

        group.throughput(Throughput::Elements(batch as u64));
        group.bench_with_input(
            BenchmarkId::new("batch", batch),
            &batch,
            |b, &n| {
                let processor  = CsiProcessor::new(CsiProcessorConfig::default()).unwrap();
                let mut sanitizer = PhaseSanitizer::new(PhaseSanitizerConfig::default()).unwrap();
                let extractor  = FeatureExtractor::default_config();
                let mut detector  = MotionDetector::default_config();

                b.iter(|| {
                    for frame in frames[..n].iter() {
                        let pre   = processor.preprocess(frame).unwrap();
                        let ph    = sanitizer.sanitize_phase(&pre.phase).unwrap();
                        let clean = CsiData::builder()
                            .amplitude(pre.amplitude.clone())
                            .phase(ph)
                            .frequency(pre.frequency)
                            .bandwidth(pre.bandwidth)
                            .snr(pre.snr)
                            .build()
                            .unwrap();
                        let feat  = extractor.extract_with_history(&clean, &history);
                        std::hint::black_box(detector.detect_human(&feat));
                    }
                });
            },
        );
    }

    group.finish();
}

criterion_group!(benches, bench_full_pipeline, bench_pipeline_stages, bench_throughput_sweep);
criterion_main!(benches);
