# G2 Bridge (iOS)

Companion app for the G2 translate glasses app (main project: `g2-translate`, kept local).
It serves a WebSocket on `127.0.0.1:5175`, receives the glasses microphone audio (16 kHz mono s16le
PCM) from the glasses app, recognizes Japanese with Apple's on-device SpeechAnalyzer, translates it
to English with Apple's on-device Translation, and sends JSON back (`hello`, `partial`, `final`,
`translation`) — the same protocol as the PC server in the main project.

- iOS 26+ (iPhone 15 Pro or newer for Apple's on-device models). Needs a real device.
- Built on GitHub's macOS runners (see `.github/workflows/build.yml`) as an **unsigned .ipa**;
  install it from Windows with Sideloadly, signed with your own (free) Apple ID. A free Apple ID's
  signature lasts 7 days.
- Keep-alive: the app plays silent audio (or runs a location session) so iOS doesn't freeze it while
  the glasses app is in front.

First run: open the app, allow Speech Recognition, wait for "speech: Japanese model ready", and tap
"Download Japanese → English translation".
