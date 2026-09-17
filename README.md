# SermonClip

Local-first macOS app for extracting a sermon from a full church-service video,
adjusting captions, adding bumpers, and exporting deliverables.

## Requirements

- Apple Silicon Mac
- macOS 26 (Tahoe) or later
- Xcode 26 or later to build/run the app bundle

Build the development app with `bash Packaging/build-app.sh`, then open
`dist/SermonClip.app`. See [Development testing](DEVELOPMENT-TESTING.md) for the
editing workflow and known limitations. The internal Swift package executable
is still named `SermonCut`. Run automated checks with `swift test`.

## Current MVP

- Persists a local opening/closing bumper library and defaults
- Imports source MP4 and SRT files with security-scoped bookmarks
- Parses SRT files, including subtitle tracks beginning at `00:00:00`
- Produces a clearly labelled sermon-boundary suggestion and requires review
- Provides native video preview, playhead boundary selection, ±5-second controls,
  and nearby-pause refinement
- Retimes supplied captions using an explicitly confirmed timeline offset
- Joins bumpers with hard cuts and retimes captions by the full opening duration
- Encodes in one hardware pass, with live video/MP3 stage percentages and estimated stage time remaining
- Exports a 1080p H.264 MP4 targeting 9 Mbps and a 128 kbps MP3

## YouTube upload (development)

See [YouTube setup and testing](YOUTUBE-SETUP.md). Includes Desktop OAuth configuration
import, Keychain storage, a single connected channel, description presets, JPG
thumbnails, visibility selection, playlist selection, and resumable uploads after local export. Live
Google sign-in/upload has not yet been validated; tests use mocked responses only.

## Detection strategy

The app intentionally separates *boundary detection* from export. An SRT that
starts at zero may be a sermon-only transcript, so timestamps alone cannot
locate it in a 90-minute service. The active suggestion path requires confirmed
caption timing and uses text keyword scoring, not a validated semantic model.
Automatic audio-to-SRT alignment is not implemented yet. Manual selection is
available without captions, and trusted supplied wording is preserved on export.
The optional local Tahoe transcription path still needs runtime/model-asset
validation. Accurate automatic detection within 30–60 seconds on a base M1
remains an unverified requirement, not a capability of this development build.
