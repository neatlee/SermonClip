# SermonClip Privacy Policy

**Effective date: September 29, 2026**

SermonClip is a local-first macOS application used to prepare church-service
videos, subtitles, and audio files. This policy explains what information the
app accesses and how it is used.

## Information stored locally

SermonClip stores project preferences, bumper-library information, description
presets, and file bookmarks on the Mac where it is installed. The video, audio,
and subtitle files selected by the user remain on that Mac unless the user
chooses to upload an export to YouTube.

Google authorization tokens are stored in the macOS Keychain. They are used to
maintain the authorized YouTube connection and are not stored in project files.

## How Google user data is protected

Security procedures are in place to protect the confidentiality of Google user
data. SermonClip stores OAuth access and refresh tokens only in the macOS
Keychain, which provides macOS-managed access controls and encryption at rest;
tokens are not written to project files, logs, or the app's preferences.
Requests containing Google user data are sent only to Google's HTTPS endpoints,
which encrypt data in transit using TLS. The app requests only the YouTube
permissions needed for its features, keeps tokens in memory only while they are
needed, and does not expose Google user data to other apps or sell it to third
parties. Users can disconnect the account in YouTube Settings, which removes
the locally stored authorization from the Keychain.

## Google and YouTube access

If the user connects a YouTube account, SermonClip uses Google OAuth to access
only the YouTube functionality required by the app, such as the connected
channel, playlists, video uploads, thumbnails, and subtitle tracks.

SermonClip uses this information only to perform actions requested by the user.
It does not sell, rent, or use Google user data for advertising, profiling, or
any unrelated purpose. Google user data is not shared with third parties except
as required to communicate with Google and YouTube APIs to complete the
requested action.

## Uploads

Nothing is uploaded to YouTube unless the user enables the YouTube upload option
and starts an export. Local exports remain on the selected export drive. The
user chooses the YouTube title, description, visibility, playlist, and
thumbnail settings before an upload begins.

## Analytics and tracking

The app does not include advertising, cross-site tracking, or third-party app
analytics. Sharing export diagnostics with SermonClip is optional and is off
until the user chooses to enable it. The choice does not affect app features,
export limits, or account access, and can be changed at any time in My Account.

When enabled, SermonClip sends a record only after an export file has been
successfully created. It includes numerical counts for MP4, MP3, and SRT files;
technical source-format details such as container, codecs, resolution, frame
rate, pixel format, color properties, and audio format; the MP4 export strategy;
whether bumpers or crossfades were used; the app version; and the time of the
export. This helps us improve format compatibility and diagnose export issues.

The app never sends the selected media, audio, subtitle contents, file names,
file paths, video titles, or embedded media tags as part of this feature. A
random app-install identifier is used to honor the preference and remove that
installation's records; the server stores only a one-way hash of it, not a
hardware identifier or device name. If the user is signed in, export records
are associated with that account so they can help with support; while signed
out, records are anonymous. SermonClip does not include the user's IP address
in these analytics records, though the hosting provider may process connection
metadata to operate and secure the service.

Turning sharing off stops future submissions from the app and deletes the
export records previously shared by that app installation, including records
associated with accounts used on it. Export diagnostics are stored by SermonClip
while sharing remains enabled, for product improvement and support; they are
not sold or used for advertising.

## Retention and deletion

The user controls local files and can remove them from the Mac at any time.
Google authorization can be disconnected from the YouTube Settings panel, and
the app can be deleted like any other macOS application. Removing the app does
not automatically delete exported media or files the user has uploaded to
YouTube; those remain under the user's control.

## Changes and contact

This policy may be updated when SermonClip's data practices change. Questions
about this policy can be directed to mike@stoneycreekbaptist.com.
