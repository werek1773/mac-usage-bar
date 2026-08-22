# Mac App Store release checklist

## Code and archive

- [x] App Store target uses `APP_STORE_BUILD=1`.
- [x] App Sandbox is enabled with only `com.apple.security.app-sandbox`.
- [x] Hardened runtime is enabled.
- [x] Memory optimization and `/usr/sbin/purge` are absent from the Store binary.
- [x] AppleScript privilege escalation and the private SkyLight framework are absent.
- [x] The Store build does not terminate other apps or read preferences from other bundle IDs.
- [x] System-wide per-process metrics, which are unavailable in App Sandbox, are omitted from the Store UI.
- [x] Privacy manifest declares no tracking and no collected data.
- [x] Version is `1.8.4` and build is `26`.
- [x] Deployment target is macOS 13.0.
- [x] Release build is universal (`arm64` and `x86_64`).
- [x] Create and validate a local test archive with stable Xcode 26.6.
- [ ] Create the production archive in Xcode Cloud on a supported stable macOS host.
- [ ] Validate and upload the Xcode Cloud archive with the paid Apple Developer team.

## App Store Connect

- [x] Confirm that the app record uses bundle ID `pl.marcin.macusagebar.final` and version `1.8.4`.
- [x] Add English and Polish metadata from `metadata.md`.
- [x] Upload at least one macOS screenshot in an accepted size.
- [x] Set category to Utilities and price to Free.
- [x] Set App Privacy to Data Not Collected.
- [x] Answer the current age-rating questions (all content categories are None for this app).
- [ ] Confirm agreements, tax/banking state, and EU DSA trader status as applicable.
- [ ] Select build 26, add review contact details, paste the review notes, and submit for review.

## Final smoke test

- [ ] Launch the exact archived/exported build on a clean user account if possible.
- [ ] Confirm the menu-bar item and dashboard appear without permission prompts.
- [ ] Confirm CPU, memory, disk, and network data refresh.
- [ ] Confirm battery behavior on both a MacBook and a desktop Mac if available.
- [ ] Confirm English/Polish switching and all four themes.
- [ ] Confirm no Optimize button is visible.
- [ ] Confirm no network connections and no unexpected sandbox denials.
