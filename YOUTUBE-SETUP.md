# Using YouTube with SermonClip

This guide covers the steps needed to install SermonClip, connect a YouTube
channel, and upload an exported sermon. Google project and OAuth client setup
are handled for the packaged app, so users do not need to create a Google
Cloud project or import a JSON file.

## Install the app

1. Download the latest DMG from the [GitHub Releases page](https://github.com/neatlee/SermonClip/releases).
2. Open the DMG and drag **SermonClip.app** to **Applications**.
3. Eject the DMG, then open SermonClip from Applications.

Alternatively, install SermonClip for the first time with Homebrew:

```sh
brew tap neatlee/sermonclip
brew trust --cask neatlee/sermonclip/sermonclip
brew install --cask neatlee/sermonclip/sermonclip
```

The app is distributed outside the Mac App Store, so macOS may show a
Gatekeeper warning the first time it opens. If that happens:

1. Close the warning.
2. Open **System Settings → Privacy & Security**.
3. Scroll to the security message for SermonClip and choose **Open Anyway**.
4. Confirm that you want to open the app.

Only use **Open Anyway** for a copy downloaded from the official SermonClip
repository or website.

## Connect your YouTube channel

1. Open SermonClip and select **YouTube Settings**.
2. Under **Account Connection**, choose **Connect to YouTube**.
3. Complete the Google sign-in and consent screens in your browser.
4. Select the church channel if Google asks which channel to use.
5. Return to SermonClip and confirm that the channel name and ID appear in the
   Account Connection section.

During the first connection, Google may show an app safety warning saying that
SermonClip has not been verified. This is an OAuth verification notice, not a
second macOS Gatekeeper warning. While verification is being completed, choose
**Advanced**, then choose the option to continue to SermonClip and finish the
connection. Only continue when you downloaded the app from the official
SermonClip repository or website.

## Export and upload

1. Select the opening and closing bumpers.
2. Choose the full Sunday service recording.
3. Set and confirm the sermon start and end points on the waveform.
4. Import an SRT or generate subtitles, then review their timing.
5. Choose the export folder and export name.
6. Select MP4 and/or MP3. An adjusted SRT is exported when subtitles are
   present.
7. To upload after export, enable **Upload to YouTube after export**. Choose
   the visibility and any other upload options before exporting.

Local exports do not require a connected YouTube account. Uploading requires
the account connection described above. YouTube may restrict visibility or
require additional authorization depending on the channel and Google’s
current policies.

## Updating SermonClip

Download the newer DMG, quit SermonClip, and replace the existing app in
Applications. Your bumper library, description presets, export preferences,
and saved YouTube authorization remain outside the app bundle and are preserved
across updates.

For privacy and local-storage details, see the [SermonClip Privacy Policy](PRIVACY.md).
For the terms governing use of the app, see the [SermonClip Terms of Service](TERMS.md).
