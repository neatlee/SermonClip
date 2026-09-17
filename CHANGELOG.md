# SermonClip Changelog

## Releases

### 1.0.1 — Bundled bumper updates & cleanup

- Automatically replaces changed protected bundled bumpers while preserving
  their IDs, names, defaults, and current selections.
- Removed obsolete legacy naming and migration paths from the fresh deployment.
- Updated bumper compatibility documentation and removed noisy test diagnostics.

### 1.0.0 — SermonClip 1.0! 🎉

- Added delayed exact-track polling for YouTube subtitle uploads so temporary
  processing delays do not produce false failure notices.
- Added background sermon/bumper loudness analysis and cached attenuation for
  bumper audio that is louder than the sermon. Quiet bumpers and sermon audio
  are never amplified or changed.
- Updated the bundled Stoney Creek opening and closing bumper with the latest
  supplied `SCB-Bumper.mp4`.

### 0.9.0 — First GitHub release

- Packaged the Stoney Creek internal Apple Silicon DMG for macOS Tahoe 26+.
- Included the bundled Stoney Creek Google OAuth configuration and default bumper.
- Added automatic migration when the bundled Google configuration changes, with
  stored authorization cleared and reconnect status shown.
- Added a secondary **Go to YouTube Settings** shortcut when upload is enabled
  without a connected channel.
- Removed the unnecessary Google Account connections link.
- Added private GitHub release packaging, version metadata, and a reproducible
  DMG build script.
- Added the DMG Applications-folder shortcut and drag-to-install layout.

## Retrospective development milestones (prior to GitHub)

### 0.8.0 — Release preparation and internal defaults

- Standardized the SermonClip product name throughout the app and storage paths.
- Added the internal Stoney Creek default opening/closing bumper and protected it
  from deletion.
- Embedded light/dark sidebar logos and the app icon into the application bundle.
- Added persistent user data migration for bumper libraries and description presets.
- Added export-folder opening from the successful export notice.
- Added MP4-only, MP3-only, and combined export selection.
- Made MP4 automatically required when YouTube upload is enabled.

### 0.7.0 — Export performance and media compatibility

- Added fast export that copies compatible source video without re-encoding.
- Added source-derived adaptive H.264 bumper conversion when bumper streams are
  incompatible with the selected sermon video.
- Added cached converted bumpers for reuse across projects.
- Preserved source resolution rather than upscaling lower-resolution recordings.
- Added JPG bumpers with six-second display timing and correct MP3 omission.
- Preserved video-bumper audio in MP3 exports while excluding image-only bumpers.
- Removed unnecessary audio-level normalization to prioritize export speed.
- Added export progress percentages and estimated time remaining.
- Added shared export names for MP4, MP3, and SRT outputs.

### 0.6.0 — YouTube publishing workflow

- Added Google OAuth sign-in using PKCE and secure macOS Keychain storage.
- Added YouTube title, description, visibility, playlist, and thumbnail controls.
- Added reusable YouTube description presets.
- Added playlist loading and refresh support.
- Added resumable upload records and retry/discard controls.
- Added automatic MP4 upload followed by subtitle-track upload.
- Added English video-language and subtitle-track handling.
- Added subtitle upload diagnostics and improved handling of accepted YouTube
  uploads whose later API step fails.
- Added private/unlisted/public visibility choices with YouTube restriction notices.

### 0.5.0 — Subtitle workflow and local transcription

- Added local subtitle generation for projects without a supplied SRT.
- Added benchmarking and completion estimates before local transcription.
- Added generated-subtitle review and adjusted-subtitle review popups.
- Added local SRT import with preserved source text and grouping.
- Added automatic matching of spoken opening/closing samples against imported SRT text.
- Added re-sync from the original imported SRT after sermon boundaries change.
- Added manual subtitle adjustment with half-second timing controls.
- Added subtitle breathing room around imported cues while clamping against neighbors.
- Added subtitle preview in the main and synchronization players.
- Added automatic selection of the first detected sermon subtitle cue.

### 0.4.0 — Waveform editing and sermon boundaries

- Replaced coarse video scrubbing with waveform-based playhead control.
- Added play/pause controls, persistent playhead time, and 15-second detail mode.
- Added draggable waveform scrubbing with shaded selected-range highlighting.
- Added green/red sermon start and end markers with caret indicators.
- Added subtitle-start marker and caret on the subtitle synchronization waveform.
- Added ±1-second and ±5-second boundary adjustment controls.
- Added nearby-pause refinement for clean spoken-word boundaries.
- Added manual takeover and clear validation when sermon start exceeds sermon end.
- Added larger video preview and native AVPlayer-based playback.

### 0.3.0 — Bumpers, captions, and export workflow

- Added persistent opening and closing bumper libraries with defaults.
- Added MP4 and JPG bumper support, thumbnails, renaming, deletion confirmation,
  and protected bundled assets.
- Added opening/closing hard cuts and correct bumper timing in exported subtitles.
- Added 1080p MP4 and MP3 export paths with configurable export destination.
- Added export-name validation and responsive draft editing.
- Added export success notices and an Open Export Folder action.
- Added first-launch export-directory selection and per-project folder changes.

### 0.2.0 — Native application foundation

- Established the native Apple Silicon SwiftUI macOS application.
- Added local MP4 selection and native playback.
- Added local SRT selection, parsing, validation, and timestamp handling.
- Added manual sermon start/end selection.
- Added initial sermon trimming and MP4/MP3 export pipeline.
- Added project persistence and security-scoped file bookmarks.
- Added the first automated test coverage for media, subtitle, and export behavior.

### 0.1.0 — Prototype foundation

- Established the initial SermonClip prototype and project structure.
- Proved the local-first workflow for a full service video, sermon selection,
  supplied subtitles, bumper insertion, and exported deliverables.
- Established the Tahoe-only target, Apple Silicon baseline, and bundled media
  encoder approach.
