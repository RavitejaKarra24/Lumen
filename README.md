# Lumen

A local-first macOS time tracker that turns your app, website, focus, and idle time into useful daily reports.

Lumen is source-distributed: it builds, signs, and installs on your Mac. No Apple Developer membership, administrator password, or global Gatekeeper changes are required.

## Features

- Track the frontmost apps, windows, browser sites, and idle time
- Review timelines, categories, tags, deep-work blocks, and focus score
- Capture visited-page context locally and turn it into learning summaries, ideas, and actions
- Set creation goals, get distraction warnings, score projects, and choose what to build next
- Export daily Markdown reports

## Requirements

- macOS 14 or later
- Xcode Command Line Tools — install once with `xcode-select --install`
- Accessibility permission on first use (for window titles and browser URLs)
- Notification permission is optional (for local distraction alerts)

## Install from source

Clone this repository, open Terminal in its directory, then run:

```bash
./install.sh
```

The installer checks for the Command Line Tools, builds a release app, generates Lumen’s icon, signs it with a persistent local-only identity, installs it to `~/Applications/Lumen.app`, verifies the installed bundle, and opens it.

It never uses `sudo`, disables Gatekeeper, or removes quarantine from anything except the app it just built locally.

## First launch and permissions

Lumen opens as a normal window and also lives in the menu bar. On the onboarding screen, choose **Open Accessibility Settings**, enable Lumen in **System Settings → Privacy & Security → Accessibility**, then return to Lumen and choose **I’ve granted access**.

Accessibility lets Lumen read the frontmost app title and browser URL for activity tracking. Your activity data stays in `~/Library/Application Support/Lumen/`; it is not uploaded by Lumen.

macOS may ask for notification permission if you enable system distraction alerts. These alerts are local.

## Launch, update, and uninstall

```bash
# Launch an installed copy
open "$HOME/Applications/Lumen.app"

# Update an existing clone, then rebuild and replace the installed app
git pull --ff-only
./install.sh

# Uninstall the app (this keeps your tracked data)
pkill -f "$HOME/Applications/Lumen.app/Contents/MacOS/Lumen" 2>/dev/null || true
rm -rf "$HOME/Applications/Lumen.app"

# Optional: also remove all local Lumen data
rm -rf "$HOME/Library/Application Support/Lumen"
```

A materially changed rebuild can cause macOS to ask for Accessibility again. If System Settings shows Lumen enabled but the app does not detect it, reset the record and run the installer again:

```bash
tccutil reset Accessibility com.lumen.app
./install.sh
```

## Development

```bash
# Build and run the signed development app
Scripts/run.sh

# Build, package, and validate the release app
Scripts/package_app.sh release

```

`Scripts/run.sh` uses the same persistent local signing identity as the installer, which helps macOS retain an Accessibility approval across ordinary rebuilds. To package with an Apple signing identity instead, use:

```bash
SIGNING_MODE=identity APP_IDENTITY="Developer ID Application: …" Scripts/package_app.sh release
```

The app icon is derived from `Assets/AppIcon.svg` by `Scripts/build_icon.sh`; do not edit the generated `Icon.icns`.

## Architecture

```text
App/       app lifecycle and UI-owned state
Views/     SwiftUI dashboard, onboarding, menu bar, and settings
Models/    activity, intelligence, and behaviour data
Services/  recording, browser inspection, persistence, insights, and goals
```

The app keeps SwiftUI state on the main actor while services handle activity capture, persistence, and analysis. Lumen’s local JSON store lives in `~/Library/Application Support/Lumen/`.

## Keyboard shortcuts

| Action | Shortcut |
| --- | --- |
| Generate daily report | ⌘⇧R |
| Export Markdown | ⌘⇧E |
| Pause / resume | ⌘⇧P |
| Run intelligence | ⌘⇧I |
| Refresh behaviour | ⌘⇧B |

## Limitations

- Lumen requires Accessibility permission for browser URL and window-title tracking.
- Website context capture requires network access to retrieve page content; core activity tracking remains local.
- This source-distribution workflow builds on each user’s Mac. It is not a notarized downloadable DMG.
