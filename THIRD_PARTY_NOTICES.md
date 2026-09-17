# Third-party notices

## FFmpeg 9.0.1 (Apple Silicon helper)

SermonClip includes an `arm64` FFmpeg executable built by Martin Riedl
(`ffmpeg.martin-riedl.de`), version `9.0.1-https://www.martin-riedl.de`.
It is used only for local delivery encoding: H.264 VideoToolbox output at a
9 Mbps target and MP3 output at 128 kbps.

That binary reports itself as licensed under the GNU General Public License,
version 3 or later. Its license text is available at
https://www.gnu.org/licenses/gpl-3.0.html. FFmpeg source is available from
https://ffmpeg.org/download.html; the binary's build configuration is
available by running `ffmpeg -version`.

Before distributing SermonClip outside the current internal users, replace this
notice with a complete source offer for this precise helper build (including
all enabled third-party libraries), or use a deliberately built LGPL-only
helper.
