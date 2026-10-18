#!/usr/bin/env bash
# video-inspect.sh - Extract sampled video frames and optional audio transcript
set -euo pipefail

PATH_ARG=""
FRAMES=8
MAX_WIDTH=768
OUT_DIR=""
TRANSCRIPT=false
TIMESTAMPS=""

print_usage() {
  cat << 'EOF'
Usage: video-inspect.sh -Path <path> [-Frames <n>] [-MaxWidth <px>] [-Timestamps <t1,t2>] [-Transcript] [-OutDir <dir>]
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -Path|--path|-p)
      PATH_ARG="$2"
      shift 2
      ;;
    -Frames|--frames|-f)
      FRAMES="$2"
      shift 2
      ;;
    -MaxWidth|--max-width|-w)
      MAX_WIDTH="$2"
      shift 2
      ;;
    -OutDir|--out-dir|-o)
      OUT_DIR="$2"
      shift 2
      ;;
    -Timestamps|--timestamps|-t)
      TIMESTAMPS="$2"
      shift 2
      ;;
    -Transcript|--transcript)
      TRANSCRIPT=true
      shift
      ;;
    -h|--help)
      print_usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      print_usage
      exit 1
      ;;
  esac
done

if [[ -z "$PATH_ARG" ]]; then
  echo "Error: -Path is required." >&2
  exit 2
fi

if [[ ! -f "$PATH_ARG" ]]; then
  echo "Error: Video not found: $PATH_ARG" >&2
  exit 2
fi

for cmd in ffmpeg ffprobe jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: '$cmd' is required. Install via: apt install ffmpeg jq (or pacman -S ffmpeg jq / dnf install ffmpeg jq)" >&2
    exit 3
  fi
done

VIDEO_REAL=$(realpath "$PATH_ARG")
BASENAME=$(basename "$VIDEO_REAL")
BASE="${BASENAME%.*}"

if [[ -z "$OUT_DIR" ]]; then
  TEMP_BASE="${TMPDIR:-/tmp}"
  STAMP=$(date +%Y%m%d-%H%M%S)
  OUT_DIR="$TEMP_BASE/video-inspect/$BASE-$STAMP"
fi

mkdir -p "$OUT_DIR"

# Metadata via ffprobe
PROBE_JSON=$(ffprobe -v error -print_format json -show_format -show_streams "$VIDEO_REAL")
DURATION=$(echo "$PROBE_JSON" | jq -r '.format.duration // 0')
SIZE_BYTES=$(echo "$PROBE_JSON" | jq -r '.format.size // null')

V_WIDTH=$(echo "$PROBE_JSON" | jq -r '[.streams[] | select(.codec_type=="video")][0].width // null')
V_HEIGHT=$(echo "$PROBE_JSON" | jq -r '[.streams[] | select(.codec_type=="video")][0].height // null')
V_FPS_RAW=$(echo "$PROBE_JSON" | jq -r '[.streams[] | select(.codec_type=="video")][0].r_frame_rate // ""')
V_CODEC=$(echo "$PROBE_JSON" | jq -r '[.streams[] | select(.codec_type=="video")][0].codec_name // null')

A_CODEC=$(echo "$PROBE_JSON" | jq -r '[.streams[] | select(.codec_type=="audio")][0].codec_name // null')
A_CHANNELS=$(echo "$PROBE_JSON" | jq -r '[.streams[] | select(.codec_type=="audio")][0].channels // null')

# Calculate FPS
V_FPS="null"
if [[ -n "$V_FPS_RAW" && "$V_FPS_RAW" == *"/"* ]]; then
  NUM=${V_FPS_RAW%/*}
  DEN=${V_FPS_RAW#*/}
  if [[ "$DEN" != "0" && -n "$NUM" ]]; then
    V_FPS=$(awk "BEGIN {printf \"%.3f\", $NUM / $DEN}")
  fi
fi

# Timestamps
TS_LIST=()
if [[ -n "$TIMESTAMPS" ]]; then
  IFS=',' read -ra ADDR <<< "$TIMESTAMPS"
  for t in "${ADDR[@]}"; do
    TS_LIST+=("$(echo "$t" | tr -d '[:space:]')")
  done
else
  DUR_INT=$(printf "%.0f" "$DURATION" 2>/dev/null || echo "0")
  if (( DUR_INT > 0 )); then
    for (( i=1; i<=FRAMES; i++ )); do
      T_CALC=$(awk "BEGIN {printf \"%.3f\", $DURATION * $i / ($FRAMES + 1)}")
      TS_LIST+=("$T_CALC")
    done
  else
    for (( i=0; i<FRAMES; i++ )); do
      TS_LIST+=("$i")
    done
  fi
fi

# Extract frames
FRAMES_JSON="[]"
IDX=0
for t in "${TS_LIST[@]}"; do
  IDX=$((IDX + 1))
  F_NAME=$(printf "frame_%02d.jpg" "$IDX")
  F_OUT="$OUT_DIR/$F_NAME"
  VF="scale='min($MAX_WIDTH,iw)':-2"

  ffmpeg -hide_banner -loglevel error -y -ss "$t" -i "$VIDEO_REAL" -frames:v 1 -vf "$VF" -q:v 3 "$F_OUT" || true
  if [[ -f "$F_OUT" ]]; then
    ITEM=$(jq -n --arg idx "$IDX" --arg t "$t" --arg p "$F_OUT" '{index: ($idx|tonumber), timestampSec: ($t|tonumber), path: $p}')
    FRAMES_JSON=$(echo "$FRAMES_JSON" | jq --argjson item "$ITEM" '. += [$item]')
  fi
done

# Transcript (optional)
TRANSCRIPT_TEXT=null
TRANSCRIPT_PATH=null
if [[ "$TRANSCRIPT" == true && -n "$A_CODEC" && "$A_CODEC" != "null" ]]; then
  AUDIO_PATH="$OUT_DIR/audio.wav"
  ffmpeg -hide_banner -loglevel error -y -i "$VIDEO_REAL" -vn -ac 1 -ar 16000 "$AUDIO_PATH" || true
  if command -v whisper &>/dev/null && [[ -f "$AUDIO_PATH" ]]; then
    whisper "$AUDIO_PATH" --model base --output_format txt --output_dir "$OUT_DIR" &>/dev/null || true
    TXT_FILE="$OUT_DIR/audio.txt"
    if [[ -f "$TXT_FILE" ]]; then
      TRANSCRIPT_PATH="\"$TXT_FILE\""
      TRANSCRIPT_TEXT=$(jq -Rs . < "$TXT_FILE")
    fi
  fi
fi

# Build JSON Summary
SUMMARY_JSON=$(jq -n \
  --arg path "$VIDEO_REAL" \
  --arg dur "$DURATION" \
  --arg w "$V_WIDTH" \
  --arg h "$V_HEIGHT" \
  --arg fps "$V_FPS" \
  --arg vcodec "$V_CODEC" \
  --arg acodec "$A_CODEC" \
  --arg ach "$A_CHANNELS" \
  --arg size "$SIZE_BYTES" \
  --argjson frames "$FRAMES_JSON" \
  --arg outDir "$OUT_DIR" \
  --argjson transText "$TRANSCRIPT_TEXT" \
  --argjson transPath "$TRANSCRIPT_PATH" \
  '{
    metadata: {
      path: $path,
      durationSec: ($dur|tonumber),
      width: (if $w != "null" then ($w|tonumber) else null end),
      height: (if $h != "null" then ($h|tonumber) else null end),
      fps: (if $fps != "null" then ($fps|tonumber) else null end),
      videoCodec: $vcodec,
      audioCodec: $acodec,
      audioChannels: (if $ach != "null" then ($ach|tonumber) else null end),
      sizeBytes: (if $size != "null" then ($size|tonumber) else null end)
    },
    frames: $frames,
    transcript: {
      available: ($transText != null),
      path: $transPath,
      text: $transText
    },
    outDir: $outDir
  }')

echo "$SUMMARY_JSON" > "$OUT_DIR/summary.json"
echo "$SUMMARY_JSON"
