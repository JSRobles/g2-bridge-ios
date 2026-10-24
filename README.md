# G2 Bridge (iOS)

Companion app for the G2 translate glasses app (main project: `g2-translate`, kept local).
It serves a WebSocket on `127.0.0.1:5175`, receives the glasses microphone audio (16 kHz mono s16le
PCM) from the glasses app, recognizes Japanese with Apple's on-device SpeechAnalyzer, translates it
to English with Apple's on-device Translation, and sends JSON back (`hello`, `partial`, `final`,
`translation`) — the same protocol as the PC server in the main project.

- iOS 26+ (iPhone 15 Pro or newer for Apple's on-device models). Needs a real device.
- Built on GitHub's macOS runners (see `.github/workflows/build.yml`) as an **unsigned .ipa**.
  Install it with **SideStore** on the phone (or iLoader from Windows), signed with your own free Apple
  ID. SideStore re-signs the app on the phone before the 7-day signature runs out; it needs its refresh
  to run (its local VPN on) and counts against a free account's active-app limit.
  Sideloadly failed here with an Apple login error (-80046), so it isn't used.
- Keep-alive: the app plays silent audio (or runs a location session) so iOS doesn't freeze it while
  the glasses app is in front.

First run: open the app, allow Speech Recognition, wait for "speech: Japanese model ready", and tap
"Download Japanese → English translation".
