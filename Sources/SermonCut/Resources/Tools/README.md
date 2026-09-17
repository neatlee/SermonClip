# Bundled FFmpeg helper

The included Apple-Silicon `ffmpeg` executable is version 9.0.1, built by
Martin Riedl, and supports `h264_videotoolbox` and `libmp3lame` encoders.
See `THIRD_PARTY_NOTICES.md` for its GPL notice and source information.

The development build deliberately falls back to `/opt/homebrew/bin/ffmpeg`
when present; that fallback is never relied on by a distributable app.
