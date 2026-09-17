# Bumper-only conversion investigation (2026-09-16)

Audio normalization was removed at the user's request to prioritize export time.
There are no runtime loudness scans or automatic gain adjustments. `BumperAudioTests`
verifies original bumper and sermon levels in both video paths and MP3 exports,
plus compatibility with library entries containing legacy audio-analysis metadata.

## Verified real-media case

- Source: `TestMedia/TestService1080.mp4`, HandBrake/x264, Main profile, Level 4.0,
  1080p30. Its SPS timing uses a 1/90000 time base.
- Bumper: `TestMedia/SCB-Bumper.mp4`, MainConcept, Main profile, Level 4.1,
  1080p30. Its original decoder configuration differs from the source.
- Re-encoding only the bumper with the following settings yielded byte-identical
  avcC decoder configuration to this source:

```text
-vf setsar=1,fps=30 -fps_mode passthrough -enc_time_base 1:90000
-c:v libx264 -preset fast -profile:v main -level:v 4.0 -crf 22
-maxrate 20000k -bufsize 25000k -g 300 -keyint_min 30 -threads 2
-color_primaries bt709 -color_trc bt709 -colorspace bt709 -color_range tv
```

Do not combine `-r 30` with this fine encoder time base and default frame-sync:
the investigation found massive frame duplication. The explicit FPS filter and
passthrough frame-sync above produced 30 fps correctly.

Original bumper audio was remuxed unchanged into the converted test file.
The opt-in `VideoCopyTests.testConvertedBumperCopyProbe` passed using this copy:
fast path only, no full encode, exact duration, and decoded-frame hashes matching
opening bumper + 75 original sermon frames (60.2–62.7s) + closing bumper.

Production now uses `BumperVideoOptimizer` to prepare variants in the background
when the source or bumper selection changes. It retains originals, validates every
candidate with `VideoCopyExporter.plan`, and caches successful variants by source
decoder configuration, bumper content, and conversion recipe. This is a
best-effort recipe, not a guarantee for every encoder configuration; unmatched
formats retain the full-encode fallback. Original bumper audio is retained in
reusable video variants without volume adjustment.

## Adaptive recipe (v2)

The converter reads a single source packet with FFmpeg `trace_headers` and maps
supported timing, reference-frame, B-frame, prediction, entropy, transform and QP
settings to libx264. It makes at most two attempts: the source-derived recipe,
then the original recipe. JPEG color range/matrix is explicitly converted to the
delivery BT.709 limited-range format. Each result must pass decoder compatibility,
duration and an error-failing decode check before entering the cache. The v2 key
does not reuse older failed-attempt markers.

Decoder compatibility still requires identical SPS/PPS bytes and AVC header
flags. Only the optional default High-profile AVC extension (4:2:0, 8-bit,
zero extra parameter sets) is normalized when comparing container metadata.

For short clips (at most 60 seconds), an inaccurate nominal frame-rate report can
be resolved by checking every compressed sample's presentation timestamp. All
samples must have a constant 1/30-second cadence; variable rates are rejected.
This is packet inspection, not pixel decoding or a full-service scan.

Implementation references: [FFmpeg codec options](https://ffmpeg.org/ffmpeg-codecs.html)
and [FFmpeg header tracing](https://ffmpeg.org/ffmpeg-bitstream-filters.html#trace_005fheaders).

The production-path real-media probe passed with the original SCB bumper:
conversion, cache reuse without re-encoding, unchanged originals, and exact
decoded-frame preservation through the fast export were verified.

The v2 probe also passed with `TestService1080-2.mp4` (High profile),
`Barnabas-Series.jpg` opening, and `SCB-Bumper.mp4` closing: both variants were
cached, fast export was selected, and all bumper frames plus 75 contiguous
original sermon frames were preserved. The test accounts for this source's
33-ms video-track start offset when comparing a non-frame-aligned cut.

Run the opt-in probe by supplying `SERMONCLIP_COPY_PROBE_SOURCE` and
`SERMONCLIP_COPY_PROBE_BUMPER` as absolute source and original bumper file paths
to `swift test`.
Add `SERMONCLIP_COPY_PROBE_IMAGE` to test a six-second JPG opening plus the video
closing bumper. The probe verifies cache reuse, unchanged originals, the fast
export path, output duration and decoded-frame hashes for the entire short export.
