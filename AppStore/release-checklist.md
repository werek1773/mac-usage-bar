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
- [x] Installed app and Xcode product name are `ResourceLens`; bundle ID remains unchanged.
- [x] The status menu includes `Quit ResourceLens`, and the app menu supports Command-Q.
- [x] Version is `1.8.4` and build is `28`.
- [x] Deployment target is macOS 13.0.
- [x] Release build is universal (`arm64` and `x86_64`).
- [x] Create and validate a local test archive with stable Xcode 26.6.
- [x] Record build 26 as rejected during automated processing with `ITMS-90301` because its build host OS was unsupported.
- [x] Build 27 succeeded in released Xcode Cloud, then was superseded before submission to remove the remaining internal `MacUsageBar` executable name.
- [x] Create the production archive for build 28 in Xcode Cloud using released Xcode 26.6 and macOS Tahoe 26.6.2.
- [x] Validate and upload build 28 with the paid Apple Developer team.

## App Store Connect

- [x] Confirm that the app record uses bundle ID `pl.marcin.macusagebar.final` and version `1.8.4`.
- [x] Change the English and Polish App Store name to `ResourceLens: System Monitor`.
- [x] Replace both subtitles with the values from `metadata.md`.
- [x] Replace screenshots and remove any submitted preview or review attachment that shows the old name.
- [x] Update the remaining English and Polish metadata from `metadata.md`.
- [x] Set category to Utilities and price to Free.
- [x] Set App Privacy to Data Not Collected.
- [x] Answer the current age-rating questions (all content categories are None for this app).
- [ ] Confirm agreements, tax/banking state, and EU DSA trader status as applicable.
- [x] Select build 28, add review contact details, paste the updated review notes, and submit for review.
- [x] Confirm App Store Connect status `Waiting for Review` on Aug 27, 2026 at 11:47 PM.

## Final smoke test

- [ ] Launch the exact archived/exported build on a clean user account if possible.
- [ ] Confirm the menu-bar item and dashboard appear without permission prompts.
- [ ] Confirm CPU, memory, disk, and network data refresh.
- [ ] Confirm battery behavior on both a MacBook and a desktop Mac if available.
- [ ] Confirm English/Polish switching and all four themes.
- [ ] Confirm `Open Dashboard` opens the panel from the status menu.
- [x] Confirm `Quit ResourceLens` terminates the exact archived build and removes its process; Command-Q uses the same standard termination action.
- [ ] Confirm no Optimize button is visible.
- [ ] Confirm no network connections and no unexpected sandbox denials.
