# Lumen: fixes, review checklist, and feature roadmap

Reviewed: 2026-09-05. Implemented: 2026-09-05 on branch `zai` — fixes F01–F15 plus the regression harness (version 0.5.0, build 5); verification items V01–V13 and the remaining architecture/feature work are still open.

This document retains the original problem statements and roadmap. F01–F15 have implementations on this branch; unchecked verification scenarios below are not a claim that every UI/runtime acceptance test has passed. See the branch-review verification section for checks actually performed.

**Evidence levels:** “Reproduced” means checked by compiling and running the relevant Swift code with synthetic inputs. “Code finding” means the behavior is visible in the implementation but has not been exercised through the running app. “Verify” means a suspected edge case or product decision, not a proven defect.

**Priorities:** P1 = address first because it affects data, privacy expectations, or core accuracy; P2 = correctness and usability; P3 = optional enhancement. Effort estimates are relative: S = a localized change, M = several components, L = a substantial feature.

## 1. What already exists

- Swift 6.2 package manifest, macOS 14 minimum, SwiftUI dashboard and menu bar, AppKit/Accessibility integration, and no declared external package dependencies.
- App/window/website recording, idle detection, pause/resume, crash recovery using observation timestamps, and sleep/wake handling.
- Daily analytics, timeline, tags and notes, category classification, deep-work blocks, focus sessions, and Markdown/CSV exports.
- Local JSON persistence with atomic file writes, delayed write batching, retention controls, and saved daily reports.
- Page/caption capture, topic extraction, generated insights, goals, distraction warnings, project suggestions, and weekly patterns.
- Local/ad-hoc signing, universal downloadable packaging, and CI checks for bundles and the committed archive.

Build on these capabilities. The roadmap below distinguishes extensions from features that are already present.

## 2. Fixes supported by the current code

### F01 — Prevent older segment copies from overwriting newer data

- [ ] **P1 · M · Code finding.** Review `IntelligenceService.runCycle`, `ActivityStore.replaceSegment` / `replaceSegments`, and the tag helpers in `AppState`.
- **Problem:** Intelligence reads a day's segments, suspends at multiple `await` points, and later replaces entire records. The capture loop also writes `var pending = segment` from the original array after reclassification. A recorder transition or note/tag edit in between can be overwritten, including `endAt` and `lastObservedAt`. Restoring an old `endAt == nil` can reopen a closed row.
- **Fix:** Perform field-specific changes inside the store actor: update enrichment, tags, and recording timestamps separately. Use a revision check where a result depends on an earlier snapshot. Make adding/removing tags atomic store operations. Do not persist captured content for a segment deleted while its request was running.
- **Verify:** Suspend a capture, close the segment, edit its tags/notes, then finish the request. All newer changes must survive, and the store must have at most one open segment.

### F02 — Make the content-capture preference apply to automatic page entry

- [ ] **P1 · M · Code finding.** Review `IntelligenceService.runNow` / `runCycle`, `IntelligenceView.onAppear`, `OnboardingView`, and `SettingsView`.
- **Problem:** `runNow` always sets `forceAll: true`; capture runs when `autoCaptureEnabled || forceAll`. Opening Intelligence calls `runIntelligence` if there is no cached report. Consequently, opening that page can fetch websites with auto-capture disabled. Capture also defaults to enabled, while onboarding says data stays on the Mac without explaining outgoing page requests.
- **Fix:** Separate local analysis, automatic fetching, and an explicitly chosen fetch/retry action. A view appearing must respect the capture setting. Recheck the preference between requests and cancel pending work when capture is turned off. Explain the network behavior in onboarding and Settings; consider an explicit first-run choice.
- **Verify:** With capture disabled, navigate through Intelligence, change dates, restart, and run local analysis using a mock network client. No request should occur unless the user chooses the separate fetch action.

### F03 — Apply retention automatically

- [ ] **P1 · S/M · Code finding.** Review `AppState.retentionDays`, `bootstrap`, `startPeriodicRefresh`, and `ActivityStore.pruneSegments`.
- **Problem:** `applyRetentionPolicy()` is only called from the setting's `didSet`. Loading a stored value during initialization does not run that observer. A 30-day policy therefore stops pruning unless the user changes the setting again.
- **Fix:** Apply retention after loading at startup and on a bounded daily schedule, including after wake. Report failures. Define retention for content, insights, focus sessions, warnings, and caches; keep saved reports according to the documented policy. Do not skip unrelated cleanup merely because no raw segments qualify for deletion.
- **Verify:** Configure 30 days, restart with 45 days of synthetic data, and cross another day without touching Settings. Old eligible data should disappear and saved reports should remain readable.

### F04 — Correct the idle backdating calculation

- [ ] **P1 · M · Code finding.** Review `ActivityRecorder.handleIdle`, `handleActive`, and the meaning of `lastObservedAt`.
- **Problem:** The recorder advances its heartbeat while waiting for the idle threshold, then clamps the idle start to that heartbeat. With a two-minute threshold and 30-second heartbeats, input stopping at 10:00 can leave a 10:01:30 heartbeat, causing about 90 seconds of inactivity to remain credited as active time.
- **Fix:** Distinguish last input time from the crash-recovery heartbeat. Reconcile the inactivity interval, including already closed segments if necessary, rather than treating a polling observation as proof of user activity.
- **Verify:** Test several threshold/heartbeat combinations, an app change during inactivity, and resume after a break. Active time should end at the intended inactivity boundary without negative or overlapping rows.

### F05 — Exclude interruptions from streak deep-work totals

- [ ] **P1 · M · Reproduced.** Review `AnalyticsService.deepWorkSecondsByDay` and `deepWorkBlocks`.
- **Problem:** Daily analytics sums `focusedDuration`, but the streak helper splits the entire block's start-to-end span across days. A synthetic 14-minute coding interval, one-minute gap, and 15-minute coding interval produced **29 minutes in daily analytics and 30 minutes in the streak table**. This can award the 30-minute streak threshold incorrectly.
- **Fix:** Keep the merged covered intervals and split those intervals by calendar day. Share the same definition of deep work between totals and streaks. Decide consistently whether a qualifying block crossing midnight qualifies both partial-day pieces.
- **Verify:** Both calculations return 29 minutes for the example. Also test gaps, overlapping focus-session intervals, midnight, and daylight-saving transitions.

### F06 — Clip all daily metrics to the selected day

- [ ] **P2 · M · Code finding.** Review `ActivityStore.behaviourInputs`, `InsightEngine.buildLearningSummary`, `IntelligenceView.classifiedCard`, and timeline duration labels.
- **Problem:** `DayAnalytics.segments` contains original overlapping segments, not clipped copies. Several consumers sum `segment.duration`, whereas headline analytics and exports use clipped durations. A 23:50–00:10 learning session can contribute 20 minutes to today's learning goal but only 10 minutes to today's active total.
- **Fix:** Introduce a shared day-bounded representation or pass the date interval explicitly into every aggregation. Distinguish full-session duration from the portion shown for a selected day.
- **Verify:** For that example, each day gets 10 minutes consistently across goals, charts, summaries, and exports. A session ending exactly at midnight contributes zero to the next day.

### F07 — Keep disabled distraction warnings disabled

- [ ] **P2 · S · Code finding.** Review `BehaviourEngine.evaluate` and `maybeEmitDistractionWarning`.
- **Problem:** Disabling warnings clears `activeWarning`, but `evaluate` later assigns the first active persisted warning unconditionally. The next evaluation can bring the toast/menu-bar warning back. A global snooze can similarly be bypassed when another unsnoozed warning remains in the list.
- **Fix:** Centralize warning eligibility and apply enabled/snooze rules both when generating warnings and when selecting the displayed warning.
- **Verify:** Create an active warning, disable warnings, and refresh repeatedly. Repeat with multiple active warnings and global snooze. Neither path should restore a suppressed warning.

### F08 — Fix report previews that remain stale or stuck loading

- [ ] **P2 · S/M · Code finding.** Review `ReportsView.loadPreview` and its change handlers.
- **Problem:** A date change can set the preview to `_Loading this day’s activity…_`. When analytics arrives, refresh occurs only if `previewMarkdown.isEmpty`, which the placeholder is not. An existing live preview also stops updating after the first nonempty render.
- **Fix:** Model preview state explicitly: saved snapshot, loading, live report, empty, or error. Refresh live/loading states when matching analytics arrives. Guard asynchronous Generate results against a subsequent date change.
- **Verify:** Move from day A to an unsaved day B with delayed analytics, including days with equal active totals. B's report must replace the placeholder without another click.

### F09 — Export the saved report being viewed

- [ ] **P2 · S/M · Code finding.** Review `ReportsView` and `AppState.exportReportToDownloads`.
- **Problem:** History displays saved snapshot Markdown, but Export always regenerates from raw activity. After retention removes those segments, an old saved report can still look complete while its Markdown export is empty or materially different.
- **Fix:** Offer an explicit saved-snapshot export using the stored Markdown. Keep live regeneration separate. Explain when CSV is unavailable because raw sessions have expired. Use a save destination or a collision-safe filename to avoid silently replacing an earlier export.
- **Verify:** Save a report, prune its raw sessions, and export it from History. Exported Markdown should match the saved preview.

### F10 — Resolve contradictory and sticky classification rules

- [ ] **P2 · M · Reproduced.** Review `CategoryClassifier.classify` and `SessionClassifier.classify`.
- **Problems reproduced:**
  - Figma's bundle is in both coding and design sets; coding wins because it is checked first.
  - An Xcode window titled `async.swift` becomes a meeting because the substring `sync` matches before coding rules.
  - A YouTube segment first classified as entertainment remains a distraction after educational content arrives because its existing entertainment category is checked before YouTube's educational rules.
- **Fix:** Make bundle rules unambiguous, use meaningful phrase/token boundaries, and recompute from base evidence rather than feeding a prior derived category back as unquestioned input. Give explicit user overrides the highest priority when they are introduced.
- **Verify:** Add the three examples above plus educational videos about programming, documentation mentioning meetings, and genuine meeting apps. Reclassification should be repeatable and respond to new evidence.

### F11 — Surface persistence failures and recover safely from corrupt files

- [ ] **P1 · M/L · Code finding.** Review `ActivityStore.loadIfNeeded`, `performFlush`, and empty catches in recorder/behaviour operations.
- **Problem:** `performFlush` retains failed dirty files but exposes no error and schedules no independent retry. A failed save may remain pending until another mutation or shutdown. One malformed JSON file can also throw out of the shared loading path and prevent otherwise healthy recording/analytics from starting.
- **Fix:** Expose persistence health, retry with a bounded backoff, and let an explicit flush report failure. Add schema/version checks, backups, and file-specific recovery. Preserve damaged files for inspection before replacing anything; never silently reset a user's history.
- **Verify:** Use temporary stores with a write failure, malformed optional data, and malformed segment data. Show an actionable error, preserve originals, and recover unsaved changes after writes become available.

### F12 — Keep launch-at-login state aligned with the actual service

- [ ] **P2 · S/M · Code finding.** Review `SettingsView.updateLoginItem` and `AppState.launchAtLogin`.
- **Problem:** The toggle persists the new preference before registration succeeds and does not restore it on failure. Startup reads only UserDefaults, so external changes to the login item can leave the UI out of sync. Debug builds deliberately skip registration but still change the preference.
- **Fix:** Wrap registration/status in a service, display the actual status, and reconcile after failure, launch, and returning from Settings. Make the debug behavior explicit.
- **Verify:** Test failed registration and externally disabled login items; the toggle must not claim the app will launch when registration did not succeed.

### F13 — Preserve note drafts when changing dates

- [ ] **P2 · M · Code finding; verify the SwiftUI event ordering.** Review `ActivityTimelineView.commitNotes` and the day picker.
- **Problem:** Draft saving looks up the old segment only in the current analytics array. Date changes have no dedicated draft-save path; once the new day's analytics replaces that array, the previous segment may no longer be available to save.
- **Fix:** Bind the draft to a stable segment ID and retain the original note value independently of the selected day's results. Commit before date changes and handle failed saves without discarding the draft.
- **Verify:** Edit a note without pressing Save, switch days quickly, and return. Repeat while background analytics refreshes.

### F14 — Scope dismissed insights deliberately

- [ ] **P2 · S/M · Code finding; confirm intended behavior.** Review `ActivityStore.insightKey` and `replaceGeneratedInsights`.
- **Problem:** Dismissal is keyed globally by kind plus lowercase title. Deleting one day's “Learning summary” suppresses future summaries with that title, and deleting a recurring topic can suppress it on all subsequent days.
- **Fix:** Separate “dismiss this occurrence” from “mute this topic.” Use a day/source-specific key for occurrences and a distinct persistent mute rule. Provide an undo/reset path.
- **Verify:** Dismiss today's learning summary, generate tomorrow's, and confirm tomorrow's still appears unless a persistent mute was explicitly selected.

### F15 — Bound downloads before loading and parsing their full bodies

- [ ] **P2 · M · Code finding.** Review `ContentCaptureService.capturePage` and the YouTube fetch paths.
- **Problem:** The 20,000-character cap is applied after `URLSession.data(from:)` has loaded the response and HTML processing has run. It does not bound download size, binary responses, or parsing memory. Some YouTube fallback paths also ignore HTTP status.
- **Fix:** Enforce response byte limits during transfer, validate status and supported content types, cancel promptly, and handle oversized/binary responses explicitly. Cache by normalized URL so repeated visits do not require identical downloads.
- **Verify:** Mock oversized, chunked, binary, redirecting, failed, and slow responses. Resource usage should stay bounded and capture should return a useful status.

## 3. Areas to check again before declaring them broken

These need focused runtime checks or a product decision. Do not rewrite them merely because a different architecture is possible.

| ID | Priority | Area and evidence | Check and possible direction |
| --- | --- | --- | --- |
| V01 | P1 | `BrowserInspector` has no explicit private-window exclusion, while README promises private windows show app time only. | Test private/incognito windows in each supported browser. If reliable detection is unavailable, document the limitation and provide explicit privacy exclusions. Test both URL and title capture. |
| V02 | P1 | `MozillaSessionReader.activeURL` falls back to the most recently accessed saved tab when no title matches; it chooses the newest recovery file across profiles. | Test multiple profiles, new tabs, repeated titles, private windows, and stale recovery files. Return unknown rather than attributing a background tab to the foreground window when confidence is insufficient. |
| V03 | P2 | `BrowserInspector.extractBrowserURL` scans other windows and arbitrary `AXURL` attributes if the focused-window lookup fails. | A title and URL may refer to different windows or a page link. Test popup windows and unusual address bars; record URL provenance/confidence and prefer verified foreground context. |
| V04 | P1 | Capture accepts arbitrary HTTP(S) URLs and follows ordinary URLSession behavior; `youtubeVideoID` uses substring host matching. *(2026-09-05: exact-host/subdomain matching and bounded, content-type-checked, cached fetches landed with F15; local-address and redirect policy remain open.)* | Define how local/intranet addresses, redirects, query tokens, and signed URLs should be handled. Match exact hosts or true subdomains, redact sensitive metadata before persistence, and test redirect policy with a local mock. |
| V05 | P2 | Sleep observers close rows, but the recorder is not explicitly suspended; stop/resume and focus start contain suspension points. | Test rapid pause/resume, double focus-start, lock/unlock, fast user switching, sleep during a transition, and quit during a save. Add lifecycle states and atomic “start if none active” operations where needed. |
| V06 | P2 | `applicationWillTerminate` waits at most four seconds for the shared store and ignores the wait result. | Test a large history and slow/failing writes. Consider coordinated asynchronous termination after stopping recorder/intelligence work; report a flush failure instead of silently timing out. |
| V07 | P2 | Weekly/project “deep work” uses creation/deep-work labels, while daily deep work uses merged qualifying blocks and explicit focus sessions. Inferred project scores include fixed estimates such as `duration * 0.4`. | Decide which metrics should agree. Label estimates clearly, calculate measured values from real segments, and separate “creation time” from “deep-work blocks” where definitions differ. |
| V08 | P2 | A focus session survives restarts by wall-clock schedule; all recorded active time inside it counts as focused, even entertainment. | Decide expected treatment of sleep, app downtime, idle periods, and distractions. Keep intentional timer completion separate from measured productive activity. |
| V09 | P2 | `selectedDay` is initialized to the current date but has no explicit “follow today” mode. | Leave the dashboard open across midnight. A Today view should follow the new day unless the user deliberately selected a historical date. Verify stale behaviour snapshots are not attached to a new day's report. |
| V10 | P2 | Markdown interpolates names/notes into markup; CSV quotes text but does not give formula-looking values a separate treatment. | Test pipes, backticks, newlines, Unicode, and text beginning with `=`, `+`, `-`, or `@` in the intended spreadsheet viewer. Define a literal-text export mode and preserve intended text. |
| V11 | P2 | Many controls are icon-only, charts use color heavily, and several panes enforce fixed minimum widths. | Test VoiceOver, keyboard-only navigation, increased text size, contrast, reduced motion, and smaller displays. Add labels/value summaries based on observed gaps. |
| V12 | P2 | Store loading removes every closed segment longer than 24 hours as crash-inflated. | Test a legitimate long idle interval and clock changes. Prefer validation/quarantine with a documented repair rule over deleting rows solely because they are long. |
| V13 | P2 | Branch review added build-number comparison and assertions for both architectures. Source provenance remains open: the embedded commit identifies the pre-commit build base, not a reproducible source-tree digest. | Test a stale zip with an unchanged marketing version or missing architecture. Add explicit provenance/build checks and architecture assertions without assuming signed binaries are byte-for-byte reproducible. |

## 4. Code organization and architecture improvements

- [x] **P2 · M — Add meaningful tests.** `Package.swift` has no test target, and CI currently verifies packaging rather than application behavior. Start with interval math, stale updates, persistence recovery, classifier cases, and capture settings. Run them in CI before packaging. *Done 2026-09-05: `Tests/LumenTests` is an executable harness (`swift run --package-path Tests LumenTests`) — without depending on XCTest or Swift Testing availability — covering deep-work math, classifiers, day clipping, store races/retention/quarantine, idle backdating, capture bounds, and run modes; CI runs it before packaging.*
- [ ] **P2 · M — Inject side effects (partially done 2026-09-05: capture client, settings store, and storage location are injectable; clock and activity source are not).** Recorder internals create their own browser inspector, idle detector, and timer; multiple services read global UserDefaults or shared singletons. Inject a clock, settings store, activity source, capture client, and storage location so tests do not inspect real windows or touch real history.
- [ ] **P2 · M — Separate database work from analysis work.** Moving analysis off the main actor is helpful, but `ActivityStore.behaviourInputs` runs expensive history analysis on the same actor that accepts recording and writes. Build immutable bounded snapshots, analyze them in a worker, and apply results only if their revision is still current.
- [ ] **P2 · M — Move expensive intelligence processing off the main actor.** `IntelligenceService` is main-actor isolated and synchronously invokes classification/topic/insight functions. Measure long days with captured text, then move those pure computations to a worker while publishing progress on the main actor.
- [ ] **P2 · M/L — Measure storage growth before choosing a replacement.** JSON plus atomic writes is reasonable for a small local app. Batching still rewrites full files and loading decodes full arrays. Benchmark realistic month/year histories; consider daily partitions or an indexed transactional store only if latency, memory, or migration needs justify it.
- [ ] **P2 · M — Centralize time and metric definitions.** Pass one `now`, calendar, and interval through an analysis pass. Repeated `.now` and full-duration calculations can create inconsistent snapshots. Define visit counts, context switches, focus score, creation time, and deep work in one place.
- [ ] **P2 · M — Split responsibilities incrementally.** Keep UI state in `AppState`, move export/login/retention orchestration to small services, and group existing services by recording, analysis, persistence, and intelligence. Split large views when components have independent state or clear reuse; file length alone is not a defect.
- [ ] **P2 · M — Make derived-data lifetime explicit.** `reportsByDay` / `artifactsByDay` grow as days are analyzed; content/focus-session caps can remove records independently of related data. Add bounded caches, stable IDs, and invalidation after retention, edits, and deletion.
- [ ] **P2 · M — Add privacy-aware diagnostics.** Replace silent catches with structured operation errors and visible recording/save health. Keep URLs, titles, notes, and content out of ordinary logs; offer a redacted diagnostic export.
- [ ] **P3 · S/M — Keep release inputs consistent.** Check deployment target/version values across `Package.swift`, `app.env`, `version.env`, and bundled metadata. Document the Swift toolchain needed to satisfy the manifest. Preserve the current local/ad-hoc distribution approach unless requirements change.

## 5. Extra features that can be added

This is a broad backlog, not a commitment to build every idea. Implement accuracy and data-protection fixes first, then select features that match how Lumen is used.

### A. More useful and controllable tracking

| Feature | Priority / effort | Useful first version / completion check |
| --- | --- | --- |
| App and website exclusions | P1 / M | Exclude bundles/domains before recording or capture; no excluded titles, URLs, or content reach storage. |
| Privacy pause presets | P2 / S/M | Pause for 15 minutes, one hour, or until tomorrow; show remaining pause time and resume predictably. |
| Tracking schedules | P2 / M | Weekday/work-hour rules, holidays, and manual overrides; test overnight schedules. |
| Manual time entries | P2 / M | Add offline work, meetings, or missed activity with validated start/end times and an origin label. |
| Timeline corrections | P2 / M/L | Split, merge, trim, delete, and reclassify segments with overlap validation and undo. |
| Idle-time review | P2 / M | After returning, optionally assign a long absence to a meeting, break, or offline task. |
| Custom classification rules | P2 / M | Ordered app/domain/title rules with a preview and explanation of which rule matched. |
| Persistent manual overrides | P2 / M | Correct category/session type once; background analysis must preserve that correction. |
| Search and multi-filter timeline | P2 / M | Search across dates, apps, domains, tags, notes, categories, and session types. |
| Meeting/media-aware idle policy | P3 / M/L | User-configurable handling of passive watching and calls, with a clear indication when time counts as active. |

### B. Better focus and habit tools

| Feature | Priority / effort | Useful first version / completion check |
| --- | --- | --- |
| Focus/break cycles | P2 / M | Extend the existing focus timer with short/long breaks and configurable rounds. |
| Pause/resume focus sessions | P2 / M | Persist pauses and clearly separate elapsed wall time from counted focus time. |
| Focus-session task/project link | P2 / M | Attach the existing timer to a task or project and show its measured contribution. |
| Daily and weekly goal schedules | P2 / M | Extend current daily goals with weekdays, weekly targets, and rest days. |
| Quiet hours and warning controls | P2 / M | Per-domain exceptions, notification cooldown controls, and no prompts during configured quiet hours. |
| End-of-day review | P2 / M | Review today's totals, correct classifications, add a reflection, and save a report. |
| Explainable scoring | P2 / M | Show the formula/evidence for focus scores and recommendations, with configurable category weights. |
| Gentle break reminders | P3 / S/M | Opt-in reminders based on sustained activity; avoid interrupting an active presentation/focus period according to user preferences. |

### C. Projects and planning

| Feature | Priority / effort | Useful first version / completion check |
| --- | --- | --- |
| Project dashboard | P2 / M | Extend existing projects with daily/weekly totals, tags, notes, and linked focus sessions. |
| Edit/archive existing projects | P2 / S/M | Expose project metadata and archive state with undo and predictable effects on historical reports. |
| Explicit project assignment | P2 / M | Assign a segment to a project without relying only on keyword matching; define whether multiple assignments share or duplicate time. |
| Project time budgets | P3 / M | Compare tracked time with a planned budget and show progress without treating inferred scores as measured completion. |
| Task checklist | P3 / M | Turn an insight into an editable task with project, status, due date, and source link. |
| Billable time and client reports | P3 / L | Optional rate/billable metadata, reviewed timesheets, and project exports; manual corrections and audit history are prerequisites. |

### D. Reports and exploration

| Feature | Priority / effort | Useful first version / completion check |
| --- | --- | --- |
| Weekly/monthly reports | P2 / M | Saved reports over custom ranges, using the same metric definitions as the dashboard. |
| Period comparisons | P2 / M | Compare this week with last week, distinguishing zero activity from missing tracking coverage. |
| Hour/day heatmaps | P2 / M | Explore focused, distracted, active, and idle time with keyboard-accessible summaries. |
| Scheduled local reports | P2 / M | Generate reports at a chosen time and catch up after sleep; no external delivery required. |
| Report customization and redaction | P2 / M | Choose sections and hide titles, full URLs, or notes before sharing. |
| Rendered report preview and PDF | P3 / M | Keep raw Markdown available, add readable rendering and a print/export layout. |
| Tracking coverage indicator | P2 / M | Show recorded, idle, paused, and unknown intervals so percentages do not imply a full day was observed. |

### E. Intelligence improvements

| Feature | Priority / effort | Useful first version / completion check |
| --- | --- | --- |
| Source-backed insight details | P2 / M | Every generated idea/action exposes its source segment and excerpt, plus whether it is a heuristic suggestion. |
| Capture queue and retry controls | P2 / M | Visible queued/failed/skipped states, individual retry, cancellation, and clear error reasons. |
| URL content cache | P2 / M | Reuse previously fetched content with an expiry; do not leak one segment's notes or metadata into another. |
| Insight editing and feedback | P2 / M | Edit, accept, reject, merge duplicates, or undo dismissal without losing changes on regeneration. |
| Persisted intelligence reports | P2 / M | Open previously analyzed days after restart without automatically fetching pages again. |
| Local search over captured knowledge | P3 / L | Search titles/topics/excerpts with source links and deletion/retention support. |
| Optional local summarization model | P3 / L | Evaluate an on-device alternative to the current heuristics with explicit resource/download controls and a lightweight fallback. |

### F. Data, macOS integration, and maintenance

| Feature | Priority / effort | Useful first version / completion check |
| --- | --- | --- |
| Backup and restore | P2 / M/L | Versioned, consistent backups of owned data/settings, a preview before restore, and a round-trip test. |
| Delete by date/app/domain; erase all data | P2 / M | Preview affected records, stop pending capture, cascade cleanup, invalidate caches, and respect the chosen treatment of saved reports. |
| Storage management panel | P2 / M | Show counts, file sizes, retention status, and the last successful disk write. |
| Optional encrypted backups | P3 / M/L | Protect exported backups with a clear recovery story; validate restore before presenting this as complete. |
| Menu-bar quick actions | P3 / S/M | Add a note, assign the current project, or pause for a duration directly from the menu bar. |
| Global shortcuts / Shortcuts actions | P3 / M | Extend existing in-app command shortcuts with configurable system-wide actions; handle conflicts clearly. |
| Read-only calendar context | P3 / M/L | Opt-in event matching for meetings, with explicit controls over stored titles and calendars. |
| Update availability and release notes | P3 / M | Start with an opt-in version check and link to the download. Consider an updater only after release provenance and signing requirements are settled. |
| Optional multi-device sync | P3 / L | Consider only after local backups, stable IDs, migrations, deletions, and conflict rules are reliable. Keep a fully local mode. |

## 6. Suggested implementation order

1. **Protect data and capture preferences:** F01–F04 and F11; establish private-window/browser attribution behavior through V01–V04.
2. **Make numbers and visible state trustworthy:** F05–F10 and F12–F15; settle the deep-work/focus-session definitions before adding more score-based features.
3. **Add regression coverage and measure performance:** test target, injected dependencies, persistence failure tests, worker-based analysis, and realistic history benchmarks.
4. **Ship practical user controls:** exclusions, manual corrections, custom classification, backup/restore, search, and reliable saved-report exports.
5. **Expand reports and focus tools:** weekly/monthly reports, comparison views, focus/break cycles, project assignment, and scheduled reviews.
6. **Evaluate larger optional features:** local models, billing workflows, calendar integration, updates, and sync based on actual user demand.

For each fix, reproduce the problem first, add a focused regression check where appropriate, implement the smallest sound change, and verify related UI/storage behavior. After user-facing app changes, follow the repository's version/archive release process. This planning-file change alone does not require rebuilding the download.

## 7. Historical verification performed for the initial plan

- During the initial planning-only pass, read the relevant source paths and packaging/CI definitions without modifying application source, settings, recorded history, signing identity, or the release artifact.
- Compiled the three model files plus analytics, category/session classifiers, and topic extraction with the installed Swift 6.3.3 toolchain in a temporary directory.
- Ran synthetic cases reproducing the **29-minute versus 30-minute deep-work mismatch**, **Figma classified as coding**, **`async.swift` classified as a meeting**, and **educational YouTube content remaining classified as distraction**.
- The full packaged app, browser permissions/private-window behavior, UI event ordering, and performance under real history were not exercised in that initial planning pass. See the later branch review below.

## 8. Branch review and merge acceptance

### Kept

- The `LumenKit` extraction and thin executable entry, field-specific store mutations, daily retention, day-clipped analytics, explicit capture modes, saved-report export, bounded downloads/cache, and regression harness.
- Pure source relocations retain their previous behavior; the review focused on semantic diffs and the newly added tests.

### Corrected during review

| Files | Regressions corrected |
| --- | --- |
| `ActivityStore.swift` | I/O failures mistaken for corruption; ignored quarantine failures; invalid schema markers overwritten; broken explicit-flush retries/health recovery; incomplete idle reconciliation. |
| `ActivityRecorder.swift`, `IntelligenceService.swift`, `ContentCaptureService.swift` | Idle gaps/overlaps and pause boundaries; heartbeats overwriting enrichment; stale queued captures; non-atomic artifact writes; cancellation busy-waits; un-cancelled transfers and automatic in-flight requests. |
| `AnalyticsService.swift`, `InsightEngine.swift`, `SessionClassifier.swift`, `BehaviourEngine.swift` | Focus anchors leaking across midnight; full-session interest weights and boundary-only insights; educational inflections lost by token matching; meetings inferred from educational content; stale evaluation errors. |
| `AppState.swift`, `NoteDrafts.swift`, timeline/settings/reports/onboarding views, `LoginItemController.swift` | Failed drafts overwritten or cleared by unrelated saves; out-of-order note writes; never-mounted reset controls; reset/read races; misleading debug/login-approval state; stale live previews and wrong-day export eligibility; failed retention attempts incorrectly marked complete; onboarding overflow and misleading privacy copy. |
| `Package.swift`, `Tests/Package.swift`, CI, packaging, README | Debug-only test imports included in ordinary release builds; stale developer instructions; missing archive build-number and universal-architecture checks. Tests now run from a separate local package. |

### Locally verified

- [x] `swift run --package-path Tests LumenTests`: **234 assertions passed, 0 failed**, using synthetic stores and mocked capture/registration services.
- [x] `swift build -c release`: normal production build, without selecting a product to hide test-target failures.
- [x] `Scripts/package_zip.sh`: rebuilt version **0.5.0 (5)** as an ad-hoc-signed **arm64 + x86_64** download; unpacked archive signature verified.
- [x] Executed the committed-download validation shell block directly from `.github/workflows/ci.yml`; version/build, signature, plist, and both architectures passed locally.
- [x] Launched the **extracted download**, not a debug substitute: it remained alive and created a window. `CFFIXED_USER_HOME` isolated Application Support, and command-line defaults disabled capture and notifications. This was only a launch smoke test; the test-owned process was then terminated.
- [x] Shell syntax and `git diff --check`; targeted strict `swift format` lint for the newly written draft/login models, their tests, the test manifest, and the onboarding view (4-space/120-column settings).

### Still not claimed as verified

- GitHub-hosted CI, first-launch Gatekeeper behavior, Intel execution (the Intel slice was built and inspected), real login-item registration, Accessibility/browser attribution, private-window behavior, sleep/wake, interactive note/export/reset workflows, and realistic-history performance.
- Remaining roadmap items are not part of this review. There is no project-wide formatter/linter configuration yet; adding one is recommended as a separate cleanup.
