---
name: video-inspect
description: Read, describe, summarize, or analyze the content of a local video file (.mp4, .mov, .mkv, .webm, etc.) when the user gives a file path. Extracts sampled frames as images (and optionally a transcript) so any text+image model can "watch" the video without native video input. Trigger on: "read this video", "what's in this video", "baca video ini", "analisa video", "summarize the video at <path>", reviewing a rendered Remotion output, or any request that points at a video file path and expects understanding of its contents.
---

# Video Inspect

Use this skill when the user points at a **local video file** and wants you to
understand, describe, summarize, or review its contents.

Models do **not** receive video through the normal `read` tool — `read` rejects
binary files (`Cannot read binary file`). This skill bridges that gap by turning
the video into inputs every model already supports: **sampled JPEG frames
(images)** plus an optional **audio transcript (text)**.

## Prerequisite

`ffmpeg` and `ffprobe` must be on PATH.
- **Windows**: `scoop install ffmpeg` (or `winget install Gyan.FFmpeg`)
- **Linux** (Debian/Ubuntu): `sudo apt install ffmpeg jq`
- **Linux** (Arch): `sudo pacman -S ffmpeg jq`
- **Linux** (Fedora): `sudo dnf install ffmpeg jq`

## Workflow

1. Run the extractor on the path the user gave:

   **Linux / macOS (Bash)**:
   ```bash
   bash "<SKILL_DIR>/scripts/video-inspect.sh" -Path "<VIDEO_PATH>" -Frames 10
   # OpenCode: "$HOME/.config/opencode/skills/video-inspect/scripts/video-inspect.sh"
   ```

   **Windows (PowerShell)**:
   ```powershell
   pwsh -NoProfile -File "<SKILL_DIR>\scripts\video-inspect.ps1" -Path "<VIDEO_PATH>" -Frames 10
   # OpenCode: "$HOME\.config\opencode\skills\video-inspect\scripts\video-inspect.ps1"
   ```

   Optional flags:
   - `-Frames <n>` — number of evenly spaced frames (default 8). More = better coverage of fast motion, more tokens.
   - `-MaxWidth <px>` — downscale frames (default 768). Lower = fewer tokens.
   - `-Timestamps 0,1.5,3` — extract exact timestamps instead of even spacing.
   - `-Transcript` — also extract audio and transcribe it with `whisper` if installed (best effort; skipped silently if unavailable).
   - `-OutDir <dir>` — output folder (default: `%TEMP%\video-inspect\<name>-<timestamp>`).

   The script prints a JSON summary: metadata (duration, resolution, fps, codecs),
   the frame image paths + timestamps, and transcript info.

2. **Read each returned frame image** with the `read` tool. The frames are
   presented to you directly. Combine them in timestamp order to reconstruct what
   happens.

3. If a transcript is present, read it and merge with the visual sequence.

4. Answer the user's question about the video. If the task needs details between
   sampled frames, re-run with `-Frames` higher or targeted `-Timestamps`.

## Limits (state these when relevant)

- You see **sampled** frames, not every frame. Very fast motion, brief flashes,
  or precise frame-level timing can be missed — raise `-Frames` to reduce that.
- Audio is only understood via transcript, and only when `whisper` is installed.
- Non-English audio needs a multilingual whisper model.

## Example

User: "baca video di C:\Users\me\Downloads\clip.mp4"

1. Run the script on that path.
2. `read` the frame images it lists.
3. Describe/summarize the video, citing timestamps of the frames.
