# Development build 0.1

The app name is SermonClip. Build with `bash Packaging/build-app.sh` and
open `dist/SermonClip.app`. No developer certificate or notarization is used;
ad-hoc signing allows the locally built Apple Silicon executable to run.

## First editing session

1. Choose an export folder. The folder is remembered between launches.
2. Import the service MP4 and choose **Select manually**.
3. Use the preview to set the first/last words. Optionally choose **Find nearby
   pauses**, then review the resulting cut.
4. Import the trusted SRT. Expand **Caption synchronization**, select a cue,
   pause the video on its first word, and choose **Match caption to playhead**.
   Preview a later cue to check the offset. Confirm matching timestamps only
   if the SRT already uses the same timeline as the video.
5. In **Manage library**, import opening/closing MP4s and select defaults if
   desired. Imported files are copied into Application Support/SermonClip/Bumpers.
6. Export MP4, MP3, and SRT. Begin with a short selection to check the result.

## Editing controls

- Remove captions is the padded X button at the top-right of the caption card.
- Bumpers now use hard cuts. Captions begin after the entire opening bumper.
- Export uses one hardware encode instead of an intermediate video plus a second
  encode. Copy-only/smart-render export is not yet implemented; 9 Mbps is a target
  for encoding, not a requirement to inflate lower-bitrate sources in a future copy path.
- Live percentages and throughput-based time estimates are shown separately for
  video (stage 1) and MP3 (stage 2). Estimates are approximate and need a few seconds
  of work; finalization is included before a stage reports success.

- Remove captions clears the selected/generated captions and alignment without
  deleting the original SRT or changing the selected video/cut.
- Preview uses a full-width 16:9 layout (non-16:9 sources are aspect-fitted).
- Start/end fields accept H:MM:SS, M:SS, or seconds, including fractional seconds.
  Press Return to apply. ±1s/±5s buttons move the boundary and pause/seek the preview.
- A local background waveform shows the selected range as a straight-edged
  shaded rectangle, with start/end markers and a playhead. Drag to seek continuously;
  releasing makes a final precise seek. The 15-second detail toggle zooms around
  the playhead and holds the visible time window fixed throughout each drag.
- The thumbnail JPG picker shares the project-level file importer, avoiding nested
  import-panel conflicts. The Export/Export & Upload button now spans the panel width.
- Waveform extraction is tested with tone and no-audio fixtures. Full-service
  waveform speed on a base M1 and the updated visual layout still need hands-on QA.

## Validation — September 14, 2026

- All 16 automated tests passed, including short single-pass video exports, both
  bumpers, caption retiming, manual takeover, pause rules, and managed-copy deletion.
- Replaced the crashing SwiftUI VideoPlayer wrapper with native AVPlayerView.
  The packaged app opened the 87:15 sample in manual preview successfully.
- Exported a 20-second sample through the GUI to TestExports: H.264 1920×1080
  at 30 fps, AAC audio, and a separate 128 kbps MP3. These are test clips from
  the beginning of the service, not the detected sermon.
- Imported all 342 supplied SRT cues through the GUI. Caption export remains
  disabled until timeline matching is confirmed; the real offset is not validated.
- Measured video bitrate was about 2.9 Mbps despite the 9 Mbps encoder request.
  The user has since confirmed that strict bitrate compliance is not required.

## Remaining development limits

Automatic semantic detection remains a keyword heuristic; review every suggestion.
Automatic audio-to-SRT matching is not yet implemented. A constant manual offset
assumes the supplied captions have no internal cuts or clock drift.
Optional Tahoe transcription still needs runtime and model-asset validation on M1.
Full-length export, export cancellation, progress UI, and the entire GUI
workflow have not yet passed release validation. The helper uses a 9 Mbps target;
hardware video bitrate can be lower. MP3 is encoded at 128 kbps.

Do not distribute this development bundle yet: complete the FFmpeg corresponding
source/license package before release.
