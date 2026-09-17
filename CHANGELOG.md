# SermonClip Changelog

## 0.9.0 — Initial internal release

First near-final internal Stoney Creek release for Apple Silicon Macs running macOS Tahoe 26 or newer.

- Trim sermon video with waveform-based start/end controls and manual fine adjustment.
- Import, automatically align, review, and export local SRT subtitles.
- Generate local subtitles when an SRT is not available.
- Export MP4, MP3, and adjusted SRT files with selectable output formats.
- Use fast, no-reencode export when the source and bumper video streams are compatible.
- Cache adaptive bumper conversions for later projects.
- Support MP4 and JPG opening/closing bumpers, including the bundled Stoney Creek default bumper.
- Manage bumper and YouTube description preset libraries.
- Upload the exported video and subtitle track to YouTube.
- Store YouTube authorization securely in the macOS Keychain.
- Automatically migrate to a newer bundled Stoney Creek Google configuration and request reconnection.
- Include a direct shortcut to YouTube Settings when upload is enabled without a connected channel.
