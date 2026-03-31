#Requires -Version 5.1
<#
.SYNOPSIS
    WiFi-DensePose v1 (Python) vs v2 (Rust) — Pipeline Benchmark Comparison

.DESCRIPTION
    Runs both benchmarks on the same synthetic CSI data
    (3 antennas × 56 subcarriers · 1 000 frames) and prints a side-by-side table.

.NOTES
    Run from RuView/:
        powershell -ExecutionPolicy Bypass -File benchmarks\run_comparison.ps1

    Prerequisites:
        - Python 3.10+ with numpy, scipy (pip install -r v1/requirements-lock.txt)
        - Rust stable ≥ 1.85 (rustup update stable)
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Script:RuViewRoot = $PSScriptRoot | Split-Path   # …/RuView/
Push-Location $Script:RuViewRoot

# ── colour helpers ──────────────────────────────────────────────────────────
function Write-Header([string]$msg) {
    Write-Host "`n$("=" * 62)" -ForegroundColor Cyan
    Write-Host "  $msg" -ForegroundColor Cyan
    Write-Host "$("=" * 62)" -ForegroundColor Cyan
}

function Write-Step([string]$msg) {
    Write-Host "`n>> $msg" -ForegroundColor Yellow
}

function Write-Ok([string]$msg) {
    Write-Host "   $msg" -ForegroundColor Green
}

# ── prerequisite check ──────────────────────────────────────────────────────
Write-Header "WiFi-DensePose Pipeline Benchmark  v1 (Python) vs v2 (Rust)"

Write-Step "Checking prerequisites …"

$python = Get-Command python -ErrorAction SilentlyContinue
if (-not $python) { $python = Get-Command python3 -ErrorAction SilentlyContinue }
if (-not $python) { throw "Python not found. Install Python 3.10+ and ensure it is on PATH." }
Write-Ok "Python : $($python.Source)"

$cargo = Get-Command cargo -ErrorAction SilentlyContinue
if (-not $cargo)  { throw "Cargo not found. Run: rustup update stable" }
$cargoVersion = (cargo --version 2>&1) -replace "cargo ", ""
Write-Ok "Cargo  : $cargoVersion"

# ────────────────────────────────────────────────────────────────────────────
# STEP 1 — Python v1 benchmark
# ────────────────────────────────────────────────────────────────────────────
Write-Step "Running Python v1 benchmark …"

$pyScript = Join-Path $Script:RuViewRoot "v1\benchmarks\benchmark_v1.py"
& $python.Source $pyScript
if ($LASTEXITCODE -ne 0) { throw "Python benchmark failed (exit $LASTEXITCODE)" }

$v1Json = Join-Path $Script:RuViewRoot "v1\benchmarks\v1_results.json"
if (-not (Test-Path $v1Json)) { throw "v1_results.json not found after Python run." }

$v1 = Get-Content $v1Json -Raw | ConvertFrom-Json

# ────────────────────────────────────────────────────────────────────────────
# STEP 2 — Rust v2 benchmark (criterion)
# ────────────────────────────────────────────────────────────────────────────
Write-Step "Running Rust v2 benchmark (criterion) …"
Write-Host "   (first run compiles; subsequent runs are faster)" -ForegroundColor DarkGray

$rustWorkspace = Join-Path $Script:RuViewRoot "rust-port\wifi-densepose-rs"
Push-Location $rustWorkspace

$criterionOutput = cargo bench `
    -p wifi-densepose-signal `
    --bench full_pipeline_bench `
    --no-default-features `
    -- full_pipeline/v2_rust_full_pipeline 2>&1

if ($LASTEXITCODE -ne 0) {
    Pop-Location
    $criterionOutput | ForEach-Object { Write-Host $_ }
    throw "Rust benchmark failed (exit $LASTEXITCODE)"
}
Pop-Location

# ── parse criterion output ───────────────────────────────────────────────────
# Criterion text format:
#   full_pipeline/v2_rust_full_pipeline
#                           time:   [16.523 µs 16.812 µs 17.124 µs]
#
# The three numbers are [lower_ci  mean  upper_ci].
# µs may appear as "µs" (U+00B5) or "us".

$rustMean_us  = $null
$rustLow_us   = $null
$rustHigh_us  = $null

foreach ($line in $criterionOutput) {
    # Match the time line: [lo_val lo_unit  mid_val mid_unit  hi_val hi_unit]
    if ($line -match 'time:\s+\[\s*([\d.]+)\s+[µu]s\s+([\d.]+)\s+[µu]s\s+([\d.]+)\s+[µu]s') {
        $rustLow_us  = [double]$Matches[1]
        $rustMean_us = [double]$Matches[2]
        $rustHigh_us = [double]$Matches[3]
        break
    }
    # Handle ns output (very fast bench)
    if ($line -match 'time:\s+\[\s*([\d.]+)\s+ns\s+([\d.]+)\s+ns\s+([\d.]+)\s+ns') {
        $rustLow_us  = [double]$Matches[1] / 1000
        $rustMean_us = [double]$Matches[2] / 1000
        $rustHigh_us = [double]$Matches[3] / 1000
        break
    }
    # Handle ms output (slow bench)
    if ($line -match 'time:\s+\[\s*([\d.]+)\s+ms\s+([\d.]+)\s+ms\s+([\d.]+)\s+ms') {
        $rustLow_us  = [double]$Matches[1] * 1000
        $rustMean_us = [double]$Matches[2] * 1000
        $rustHigh_us = [double]$Matches[3] * 1000
        break
    }
}

if ($null -eq $rustMean_us) {
    Write-Host "`nFull criterion output:" -ForegroundColor Red
    $criterionOutput | ForEach-Object { Write-Host $_ }
    throw "Could not parse criterion output. See above."
}

$rustFps = 1_000_000 / $rustMean_us

# ────────────────────────────────────────────────────────────────────────────
# STEP 3 — Comparison table
# ────────────────────────────────────────────────────────────────────────────
$speedup = $v1.mean_us / $rustMean_us
$pctFaster = ($speedup - 1) * 100

Write-Header "Results"

$col1 = 26
$col2 = 16
$col3 = 16

$hdr = "{0,-$col1}{1,$col2}{2,$col3}" -f "Metric", "Python v1", "Rust v2"
$sep = "-" * ($col1 + $col2 + $col3)

Write-Host $hdr -ForegroundColor White
Write-Host $sep

function Row([string]$label, [string]$py, [string]$rs) {
    Write-Host ("{0,-$col1}{1,$col2}{2,$col3}" -f $label, $py, $rs)
}

Row "Mean latency"   ("{0:N1} µs" -f $v1.mean_us)   ("{0:N2} µs" -f $rustMean_us)
Row "Median latency" ("{0:N1} µs" -f $v1.median_us)  "—"
Row "p95 latency"    ("{0:N1} µs" -f $v1.p95_us)     "—"
Row "p99 latency"    ("{0:N1} µs" -f $v1.p99_us)     "—"
Row "CI 95%"         "—"   ("[{0:N2} – {1:N2} µs]" -f $rustLow_us, $rustHigh_us)
Row "Throughput"     ("{0:N0} fps" -f $v1.fps)        ("{0:N0} fps" -f $rustFps)

Write-Host $sep
Write-Host ""
Write-Host ("  Speedup  (mean): {0:N0}x  ({1:N0}% faster)" -f $speedup, $pctFaster) `
    -ForegroundColor $(if ($speedup -gt 100) { "Green" } else { "Yellow" })
Write-Host ""

# ── annotate vs claimed ──────────────────────────────────────────────────────
Write-Host "  Claimed speedup in README : ~810x" -ForegroundColor DarkGray
Write-Host ("  Measured speedup          : {0:N0}x" -f $speedup) -ForegroundColor DarkGray
if ([math]::Abs($speedup - 810) / 810 -lt 0.3) {
    Write-Host "  -> Within 30% of the claimed value." -ForegroundColor Green
} else {
    Write-Host ("  -> Deviates from claimed 810x. " +
                "Verify Python baseline uses same pipeline scope.") -ForegroundColor Yellow
}

# ── save combined JSON ───────────────────────────────────────────────────────
$combined = [ordered]@{
    python_v1 = $v1
    rust_v2   = [ordered]@{
        language    = "Rust v2"
        pipeline    = "preprocess -> sanitize_phase -> extract_with_history -> detect_human"
        mean_us     = $rustMean_us
        ci_low_us   = $rustLow_us
        ci_high_us  = $rustHigh_us
        fps         = $rustFps
    }
    comparison = [ordered]@{
        speedup_x          = [math]::Round($speedup, 1)
        python_mean_ms     = [math]::Round($v1.mean_us / 1000, 3)
        rust_mean_us       = [math]::Round($rustMean_us, 2)
        claimed_speedup_x  = 810
    }
}

$outPath = Join-Path $PSScriptRoot "comparison_results.json"
$combined | ConvertTo-Json -Depth 4 | Set-Content $outPath -Encoding UTF8
Write-Host "`n  Full results -> $outPath" -ForegroundColor DarkGray

Pop-Location
