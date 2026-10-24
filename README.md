# G2 Bridge (iOS)

Companion app for the G2 translate glasses app (main project: `g2-translate`, kept local).
It serves a WebSocket on `127.0.0.1:5175`, receives the glasses microphone audio (16 kHz mono s16le
PCM) from the glasses app, recognizes Japanese with Apple's on-device SpeechAnalyzer, translates it
to English with Apple's on-device Translation, and sends JSON back (`hello`, `partial`, `final`,
`translation`) — the same protocol as the PC server in the main project.

- iOS 26+ (iPhone 15 Pro or newer for Apple's on-device models). Needs a real device.
- Built on GitHub's macOS runners (see `.github/workflows/build.yml`) as an **unsigned .ipa**; every
  push to `main` publishes a release (`v<MARKETING_VERSION>` from `project.yml`; bump it for each build)
  with `G2Bridge.ipa` and a SideStore source file `source.json`.
- **Install and update with SideStore:** add this source once (Sources tab → +):

      https://github.com/JSRobles/g2-bridge-ios/releases/latest/download/source.json

  It always points at the newest release, and SideStore offers an update whenever the version goes up.
  The direct link to the newest `.ipa` is
  `https://github.com/JSRobles/g2-bridge-ios/releases/latest/download/G2Bridge.ipa`.
  SideStore re-signs the app on the phone with your free Apple ID before the 7-day signature runs out
  (its refresh must be able to run, with its local VPN on) and counts against the free account's
  active-app limit. Sideloadly failed here with an Apple login error (-80046), so it isn't used.
- Keep-alive: the app plays silent audio (or runs a location session) so iOS doesn't freeze it while
  the glasses app is in front.

First run: open the app, allow Speech Recognition, wait for "speech: Japanese model ready", and tap
"Download Japanese → English translation".

## Using the app
Three tabs show the finished sentences (newest at the bottom): **Both** (Japanese with its English
underneath), **Japanese** only, **English** only. The gear opens Settings: bridge status, the two
keep-alive switches, the translation-language download, "clear all sentences" and the log. The
keep-alive switches and the last tab are remembered between launches.
