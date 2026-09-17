# YouTube upload development build

## Connect

1. Enable YouTube Data API v3 in your Google Cloud project.
2. Configure Google Auth platform; add your Google account as a test user if the
   audience is External and the publishing status is Testing.
3. Create a Desktop app OAuth client and download its JSON. Do not add it to this
   repository or paste credentials into chat.
4. Open SermonClip's **YouTube Settings** sidebar item and import that JSON locally.
5. Choose **Connect YouTube**. Approve access in Google's browser page and select
   the church's channel if offered. Verify the channel name shown in Settings.

The app uses PKCE, a random state value, and a loopback-only callback listener.
It requests youtube.upload, youtube.readonly, and youtube.force-ssl so it can add
an uploaded video to a selected playlist. Configuration, refresh/access
tokens, and resumable-upload records are stored in macOS Keychain. The app does
not read browser cookies or store a Google password. Developer ad-hoc builds may
prompt again for Keychain access after rebuilding. Disconnect removes the local
authorization; Google's grant can be revoked separately in Google Account settings.

## Prepare an upload

- Use **Descriptions** in the sidebar to create/edit named presets. Applying a
  preset copies text into the current draft, without linking subsequent edits.
- Select **Upload to YouTube after export**, supply a title/description, optionally
  select a local JPG no larger than 2 MiB, and choose Private/Unlisted/Public.
- Use the **Playlist** picker to choose an existing playlist owned by the connected
  channel. **Refresh playlists** reloads the list after changes made in YouTube;
  the video is added after upload. Leave it at **No playlist** to skip assignment.
- The toggle is off and visibility is Private at each launch. Export & Upload asks
  for explicit confirmation, including the channel and chosen visibility.
- Existing local MP4/MP3/SRT export completes first. Only the final MP4, metadata,
  and selected thumbnail are uploaded. SRT upload is not part of this first version.
- Public uploads can become visible before the thumbnail step finishes. Audience
  settings are not assigned by SermonClip; check the channel defaults and YouTube Studio.

## Progress and recovery

Video transfer uses 4 MiB chunks. Progress advances on Google-confirmed chunks;
time remaining is estimated from observed throughput. Network errors pause with
an actionable message rather than automatic endless retries. Resume queries the
existing upload session before sending more bytes. The source's size and modification
time must still match. Restarting SermonClip never resumes or publishes automatically.
Once Google supplies a video ID, retries target only the remaining thumbnail/status
steps. Discarding a retry record does not delete local files or YouTube videos.
Check Studio before starting a new job after an expired session or ambiguous error.

After upload, SermonClip checks returned privacy status. A mismatch is reported rather
than claiming successful publication. YouTube's own HD processing can continue
after the transfer completes. Private uploads are useful for initial live testing.

## Google restrictions

- External OAuth apps in Testing generally have seven-day refresh-token expiry.
- New unverified YouTube API projects restrict uploads to Private. Public/Unlisted
  operation requires lifting the separate project restriction through Google's audit.
- Custom thumbnails require channel eligibility/permissions. API quota, upload
  limits, and longer-video eligibility still apply.

Sources checked September 14, 2026:
- https://developers.google.com/identity/protocols/oauth2/native-app
- https://developers.google.com/youtube/v3/guides/using_resumable_upload_protocol
- https://developers.google.com/youtube/v3/docs/videos/insert
- https://developers.google.com/youtube/v3/docs/thumbnails/set

## Validation boundary

Unit/integration tests use in-memory credentials and a mock HTTP transport. No
real account was connected and no real video uploaded during development testing.
The browser callback, real Keychain prompts, Google consent configuration, live
thumbnail eligibility, and full-length upload must be validated with the owner.
