[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Path,
  [int]$Frames = 8,
  [int]$MaxWidth = 768,
  [string]$OutDir,
  [switch]$Transcript,
  [double[]]$Timestamps
)

$ErrorActionPreference = 'Stop'
$inv = [System.Globalization.CultureInfo]::InvariantCulture

if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
  Write-Error "Video not found: $Path"
  exit 2
}
$video = (Resolve-Path -LiteralPath $Path).Path

foreach ($exe in 'ffmpeg', 'ffprobe') {
  if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) {
    Write-Error "'$exe' not found on PATH. Install ffmpeg (e.g. 'scoop install ffmpeg')."
    exit 3
  }
}

$base = [System.IO.Path]::GetFileNameWithoutExtension($video)
if (-not $OutDir) {
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $OutDir = Join-Path $env:TEMP "video-inspect\$base-$stamp"
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# --- metadata ---
$probe = (& ffprobe -v error -print_format json -show_format -show_streams $video) | ConvertFrom-Json
$vStream = $probe.streams | Where-Object { $_.codec_type -eq 'video' } | Select-Object -First 1
$aStream = $probe.streams | Where-Object { $_.codec_type -eq 'audio' } | Select-Object -First 1

$duration = 0.0
if ($probe.format.duration) { $duration = [double]$probe.format.duration }
$sizeBytes = $null
if ($probe.format.size) { $sizeBytes = [long]$probe.format.size }

function ConvertTo-Fps([string]$rate) {
  if (-not $rate) { return $null }
  $p = $rate -split '/'
  if ($p.Count -eq 2 -and [double]$p[1] -ne 0) {
    return [math]::Round(([double]$p[0] / [double]$p[1]), 3)
  }
  return $null
}

$meta = [ordered]@{
  path          = $video
  durationSec   = $duration
  width         = $vStream.width
  height        = $vStream.height
  fps           = (ConvertTo-Fps $vStream.r_frame_rate)
  videoCodec    = $vStream.codec_name
  audioCodec    = $aStream.codec_name
  audioChannels = $aStream.channels
  sizeBytes     = $sizeBytes
}

# --- timestamps (evenly spaced by default) ---
if (-not $Timestamps -or $Timestamps.Count -eq 0) {
  $ts = @()
  if ($duration -gt 0) {
    for ($i = 1; $i -le $Frames; $i++) {
      $ts += [math]::Round($duration * $i / ($Frames + 1), 3)
    }
  }
  else {
    for ($i = 0; $i -lt $Frames; $i++) { $ts += [double]$i }
  }
  $Timestamps = $ts
}

# --- extract frames ---
$frameFiles = @()
$idx = 0
foreach ($t in $Timestamps) {
  $idx++
  $out = Join-Path $OutDir ('frame_{0:d2}.jpg' -f $idx)
  $tStr = ([double]$t).ToString($inv)
  $vf = "scale='min($MaxWidth,iw)':-2"
  & ffmpeg -hide_banner -loglevel error -y -ss $tStr -i $video -frames:v 1 -vf $vf -q:v 3 $out
  if (Test-Path -LiteralPath $out) {
    $frameFiles += [pscustomobject]@{ index = $idx; timestampSec = [double]$t; path = $out }
  }
}

# --- transcript (optional, best effort) ---
$transcriptText = $null
$transcriptPath = $null
if ($Transcript -and $aStream) {
  $audioPath = Join-Path $OutDir 'audio.wav'
  & ffmpeg -hide_banner -loglevel error -y -i $video -vn -ac 1 -ar 16000 $audioPath
  if ((Get-Command whisper -ErrorAction SilentlyContinue) -and (Test-Path -LiteralPath $audioPath)) {
    try {
      & whisper $audioPath --model base --output_format txt --output_dir $OutDir | Out-Null
      $txt = Join-Path $OutDir 'audio.txt'
      if (Test-Path -LiteralPath $txt) {
        $transcriptPath = $txt
        $transcriptText = (Get-Content -LiteralPath $txt -Raw).Trim()
      }
    }
    catch { }
  }
}

$summary = [ordered]@{
  metadata   = $meta
  frames     = $frameFiles
  transcript = [ordered]@{
    available = [bool]$transcriptText
    path      = $transcriptPath
    text      = $transcriptText
  }
  outDir     = $OutDir
}

$json = $summary | ConvertTo-Json -Depth 6
$summaryPath = Join-Path $OutDir 'summary.json'
$json | Set-Content -LiteralPath $summaryPath -Encoding UTF8
$json
