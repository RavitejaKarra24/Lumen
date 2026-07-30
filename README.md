# Lumen

Lumen is a time tracker for your Mac. It quietly notices which apps and websites you use, when you are focused, and when you step away, then turns that into a daily report you can actually read. Your activity stays on your Mac.

- **Just want to use it?** Read [Install and use](#install-and-use).
- **Want to read or change the code?** Read [For developers](#for-developers).

Requirements: macOS 14 (Sonoma) or later, on either an Apple silicon or an Intel Mac.

---

# Install and use

## First, the security warning

The first time you open Lumen, macOS will refuse and show a warning that it cannot check the app for malware.

**This is expected. It means the app has not paid for Apple's notarization, not that anything is wrong with it.** Notarization requires an Apple Developer membership that costs $99 a year, and Lumen is a free project that hasn't bought one. Steps 4 to 6 below walk you past the warning.

**You only have to do this once.** After that, Lumen opens like any other app.

## 1. Download Lumen

**[Download Lumen.zip](https://github.com/RavitejaKarra24/Lumen/raw/main/Lumen.zip)** — about 3 MB.

## 2. Unzip it

Open your **Downloads** folder and double-click **Lumen.zip**. A **Lumen** app icon appears next to it.

## 3. Move it to Applications

Drag the **Lumen** icon into your **Applications** folder. (Open a new Finder window and pick **Applications** in the sidebar if you need somewhere to drag it to.)

## 4. Try to open it — and expect to be stopped

Double-click **Lumen** in your Applications folder. A dialog appears saying macOS could not verify that Lumen is free of malware.

Click **Done**. On older versions of macOS the button is called **Cancel**.

**Do not click "Move to Trash"** — that deletes the app and you would have to start over.

## 5. Allow Lumen in System Settings

1. Open the  menu in the top-left corner and choose **System Settings**.
2. Click **Privacy & Security** in the sidebar.
3. Scroll down to the **Security** section near the bottom. You will see a line saying **Lumen** was blocked, with an **Open Anyway** button next to it.
4. Click **Open Anyway** and confirm with Touch ID or your Mac's password.

If you do not see the **Open Anyway** button, it has timed out — it only appears for a few minutes after a blocked launch. Go back to step 4, try opening Lumen again, then come straight back here.

## 6. Confirm

One more dialog appears. Click **Open Anyway**.

Lumen opens. That was the last time you will see any of this.

## 7. Give Lumen permission to see your windows

Lumen opens on a welcome screen asking for Accessibility permission.

1. Click **Open Accessibility Settings**. System Settings opens on the right page.
2. Turn on the switch next to **Lumen** in the list.
3. Switch back to Lumen and click **I've granted access**, then **Start tracking**.

Accessibility is the only way for macOS to tell Lumen the title of the window you are looking at and the address of the page open in your browser. Without it, Lumen can only see which app is in front, and your reports will be much thinner.

macOS may also ask for permission to send you notifications. That is optional, and only used for the distraction alerts you can turn on in Settings.

## Where Lumen appears

- **A window** — the dashboard, with Today, Apps, Websites, Reports, and Settings down the left side.
- **In the Dock**, like a normal app.
- **In the menu bar**, near the clock: a small dot. Click it for **Open Dashboard**, **Pause Tracking**, **Start Focus Session**, **Generate Today's Report**, and **Quit Lumen**.

**Closing the dashboard window does not stop tracking.** Lumen keeps running in the menu bar, which is the point. To get the window back, click the menu bar dot and choose **Open Dashboard**. To stop Lumen entirely, click the menu bar dot and choose **Quit Lumen** — that also saves whatever it was in the middle of recording.

The menu bar dot changes shape to tell you what is happening: a pause symbol when tracking is paused, a moon when you have gone idle, a countdown during a focus session, and a warning triangle if Accessibility permission is missing.

## Updating

1. Click the menu bar dot and choose **Quit Lumen**.
2. Download the zip again from the link in step 1, and unzip it.
3. Drag the new **Lumen** into **Applications** and choose **Replace** when asked.
4. Open it. The security warning from steps 4 to 6 may appear again for the new version — the same four clicks fix it.
5. **macOS may ask for Accessibility permission again.** This is normal for an app without a paid Apple signature: macOS ties permissions to the app's signature, and a free signature changes with every release. If tracking looks dead after an update, turn Lumen off and back on in **System Settings → Privacy & Security → Accessibility**.

Updating never touches the activity Lumen has already recorded.

## Uninstalling

1. Click the menu bar dot and choose **Quit Lumen**.
2. Open **Applications** and drag **Lumen** to the Trash.
3. To also delete everything Lumen recorded: in Finder, open the **Go** menu, choose **Go to Folder**, type `~/Library/Application Support/Lumen`, and press Return. Drag the **Lumen** folder to the Trash.
4. Optionally, remove the leftover entry for Lumen in **System Settings → Privacy & Security → Accessibility** using the **−** button.

That is everything. Lumen does not install background helpers, and it does not change any system settings that would need putting back.

## Your privacy

- Everything Lumen records — apps, window titles, websites, focus sessions, reports — is written to plain files in `~/Library/Application Support/Lumen` on your Mac. There is no account, no server, no analytics, and no telemetry.
- **One thing does leave your Mac.** Lumen's Intelligence feature re-fetches the web pages you visited (and YouTube caption tracks) so it can summarise what you were reading. Those requests go to the websites themselves. It is **on by default** — turn off **Auto-capture page content & transcripts** in **Settings → Intelligence** if you would rather nothing left the machine. Everything else keeps working with it off.
- Lumen does not take screenshots, record what you type, or read the contents of your documents.
- **Settings → Data** can limit how long raw activity is kept. Generated reports are never deleted automatically.

## If something looks wrong

**Nothing happens when I double-click Lumen.** Either the first-launch block is still in the way (steps 4 to 6), or Lumen is already running — look for the dot in the menu bar and choose **Open Dashboard**.

**"Open Anyway" isn't in System Settings.** It only appears for a few minutes after a blocked launch. Try opening Lumen again, then look immediately.

**The dashboard is empty, or says there's no activity.** Accessibility permission is missing. The menu bar icon will be a warning triangle. Follow step 7.

**It shows app names but no window titles or websites.** Same cause — Accessibility permission. Follow step 7.

**It asked for Accessibility again after I updated.** Expected. See [Updating](#updating).

**I closed the window and can't find Lumen.** Click the dot in the menu bar and choose **Open Dashboard**.

**Time stopped adding up.** Tracking is probably paused — the menu bar icon shows a pause symbol. Click it and choose **Resume Tracking**, or press ⌘⇧P.

**Websites aren't showing up.** Lumen reads the address bar of Safari, Chrome, Brave, Edge, and Firefox. Browsers outside that list, and private windows, will show as app time without a site.

**I clicked "Move to Trash" by mistake.** Nothing is broken — download the zip again and start from step 2.

*The exact dialog wording and the layout of System Settings were checked against macOS 26 in July 2026. Apple moves these around between releases. If what you see does not match word for word, the shape is the same: try to open the app, then allow it under Privacy & Security.*

## Keyboard shortcuts

| Action | Shortcut |
| --- | --- |
| Generate daily report | ⌘⇧R |
| Export Markdown | ⌘⇧E |
| Pause / resume tracking | ⌘⇧P |
| Run intelligence | ⌘⇧I |
| Refresh behaviour | ⌘⇧B |

---

# For developers

## Clone, build, run

Requires macOS 14 or later and the Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/RavitejaKarra24/Lumen.git
cd Lumen
./install.sh
```

`install.sh` builds a release app, generates the icon, signs it with a persistent local-only identity, installs it to `~/Applications/Lumen.app`, verifies the installed bundle, and opens it. It never uses `sudo`, disables Gatekeeper, or removes quarantine from anything except the app it just built.

A locally built app is never quarantined, so you will not see the security prompt described in [Install and use](#install-and-use). The only way to see what users see is to download the zip from GitHub yourself, ideally on a second Mac or a fresh user account.

## Commands

```bash
swift build                                 # compile only
Scripts/run.sh                              # build, sign locally, and launch
Scripts/package_app.sh release              # build Lumen.app at the repo root
Scripts/package_zip.sh                      # regenerate the downloadable Lumen.zip
./install.sh                                # build and install to ~/Applications
```

There is no test target yet. CI (`.github/workflows/ci.yml`) builds the app on every push, ad-hoc signs it, and verifies the bundle and the zip.

`Scripts/run.sh` and `install.sh` use a persistent local signing identity created by `Scripts/setup_local_signing.sh`, which keeps an Accessibility approval valid across ordinary rebuilds. To package with a real Apple identity instead:

```bash
SIGNING_MODE=identity APP_IDENTITY="Developer ID Application: …" Scripts/package_app.sh release
```

The app icon is generated from `Assets/AppIcon.svg` by `Scripts/build_icon.sh`. Do not edit the generated `Icon.icns`.

## Distribution model

Lumen ships two ways, and it is worth knowing why before changing either.

**Source** — clone and run `./install.sh`. Signed with a machine-local identity that exists only in your keychain.

**A committed zip** — `Lumen.zip` at the repo root, built by `Scripts/package_zip.sh`, downloaded straight from `raw/main`. It is **ad-hoc signed** (`codesign --sign -`), which is free and satisfies the Apple silicon requirement that every binary carry a signature, but it is **not notarized**, because notarization requires the $99/year Apple Developer membership. That is why users hit a first-launch prompt, and why the install steps above are written the way they are.

Please don't add notarization or Developer ID steps to the build scripts — nobody here has credentials to run them, and half-wired signing steps fail confusingly in CI. If the project ever buys a membership, the migration is additive: swap `--sign -` for `--sign "Developer ID Application: …"`, add `xcrun notarytool submit --wait` and `xcrun stapler staple`, and delete the security-warning steps from the README.

The zip is committed rather than attached to a GitHub Release because it is ~3 MB and releases are rare. If it grows past ~10 MB, or releases become frequent, switch to `gh release create` and point the download link at `releases/latest` instead — every git commit of the zip lives in history forever.

## Regenerating the download

`Lumen.zip` is a build artifact stored in source control, and git will not tell you it is stale. **Regenerate it in the same commit as any user-facing change**, along with a version bump:

```bash
$EDITOR version.env          # bump MARKETING_VERSION and BUILD_NUMBER
Scripts/package_zip.sh
git add Lumen.zip version.env
```

`Scripts/package_zip.sh` builds a universal (arm64 + x86_64) binary, ad-hoc signs it, verifies the bundle, archives it with `ditto -c -k --keepParent`, then unpacks that archive to a temp directory and re-verifies the signature there. The `ditto` part is not optional: `zip` drops symlinks and extended attributes, which invalidates the signature and produces an app that fails to launch on Apple silicon with no useful error. Because there is no auto-updater, `CFBundleShortVersionString` is the only way a user can tell what they are running.

## Layout

```text
Sources/Lumen/App/        app lifecycle and UI-owned state
Sources/Lumen/Views/      SwiftUI dashboard, onboarding, menu bar, settings
Sources/Lumen/Models/     activity, intelligence, and behaviour data
Sources/Lumen/Services/   recording, browser inspection, persistence, insights, goals
Scripts/                  build, icon, signing, packaging
Assets/AppIcon.svg        icon source; Icon.icns is generated from it
app.env                   app name, bundle id, minimum OS
version.env               marketing version and build number
install.sh                source install for developers
Lumen.zip                 the committed download; regenerate, never hand-edit
```

## Architecture

SwiftUI state stays on the main actor while services handle activity capture, persistence, and analysis. Activity is stored as JSON in `~/Library/Application Support/Lumen/`. Writes are batched and flushed on a short delay rather than after every observation, and the day's analysis runs off the main thread, so the interface stays responsive as history grows.

**How deep work is measured.** The recorder starts a new session whenever the window title changes, so a long stretch of work arrives as dozens of short segments. Lumen merges adjacent focused segments into a single block, bridging interruptions shorter than two minutes, and counts a block once it spans 25 minutes or more. Only the focused time inside a block counts, not the interruptions it bridged. Time inside an explicit focus session always counts, even if the session is ended early.

## Limitations

- Accessibility permission is required for window titles and browser URLs. Without it, only the frontmost app name is available.
- Browser URL extraction reads the address bar through Accessibility, and is tuned for Safari, Chrome, Brave, Edge, and Firefox. Other browsers fall back to app-level tracking.
- Website context capture needs network access to fetch page content. Core activity tracking stays local.
- Ad-hoc signatures change between builds, so macOS may re-prompt for Accessibility after every update. This is the strongest practical argument for eventually paying for a Developer ID.
- No auto-updater. Users find out about new versions by coming back to this page.
