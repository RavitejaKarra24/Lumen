# Lumen

Local-first macOS time tracker inspired by [rize.io](https://rize.io).

Lumen records what you do on your Mac, understands it, then helps you behave like a builder — goals, distraction guards, project scores, and a ranked “what to build next.”

## Goalposts

| Stage | Status | Scope |
| --- | --- | --- |
| **1 · Recorder** | ✅ | Apps, websites, idle, tags, daily Markdown reports |
| **2 · Intelligence** | ✅ | Page/transcript capture, classification, interests, ideas/actions |
| **3 · Behaviour engine** | ✅ | Distraction warnings, creation goals, project scoring, weekly patterns, next-build picker |

## Features

### Recorder
- Menu bar + dashboard
- App / window / URL tracking
- Idle detection, categories, tags, notes
- Focus score + deep-work blocks
- Daily Markdown reports

### Intelligence
- Page text + YouTube transcript capture
- Session kinds (deep work, learning, distraction, …)
- Topic extraction + repeated interests
- Learning summaries, ideas, action items

### Behaviour engine
- **Distraction warnings** — in-app toast, menu bar, optional system notifications
- **Creation goals** — deep work, creation, learning, focus score, distraction caps
- **Project scoring** — keyword-matched projects scored on time, deep work, momentum
- **Weekly patterns** — hour-of-day and weekday focus/distraction shapes
- **What to build next** — ranked recommendations from actions, ideas, projects, interests

## Requirements

- macOS 14+
- Accessibility permission
- Network optional (content capture)
- Notification permission optional (distraction alerts)

## Build & run

```bash
swift build
Scripts/run.sh
```

`Scripts/run.sh` signs development builds with a persistent, self-signed local identity stored in `~/Library/Application Support/Lumen Development Signing/`. This keeps the macOS Accessibility grant valid across rebuilds. The first run after switching from an ad-hoc build resets the stale permission record; grant Accessibility once more when Lumen prompts you.

For a distributable build, provide an Apple signing identity instead:

```bash
SIGNING_MODE=identity APP_IDENTITY="Developer ID Application: …" Scripts/run.sh
```

### Accessibility troubleshooting

If System Settings shows Lumen enabled but the app still says permission is missing, the old grant is tied to a previous ad-hoc build. Run:

```bash
tccutil reset Accessibility com.lumen.app
Scripts/run.sh
```

Then click **Grant Accessibility** and enable Lumen once. Do not run the raw `.build/debug/Lumen` executable; launch `Lumen.app` so macOS checks the stable app identity.

## Architecture

```
Services/
  ActivityRecorder · BrowserInspector · ContentCapture
  SessionClassifier · InsightEngine · IntelligenceService
  BehaviourEngine · ProjectScorer · WeeklyPatternAnalyzer · NextBuildEngine
```

Data: `~/Library/Application Support/Lumen/`  
(`segments`, `content`, `insights`, `goals`, `projects`, `warnings`, …)

## Shortcuts

| Action | Shortcut |
| --- | --- |
| Generate daily report | ⌘⇧R |
| Export Markdown | ⌘⇧E |
| Pause / resume | ⌘⇧P |
| Run intelligence | ⌘⇧I |
| Refresh behaviour | ⌘⇧B |

## Privacy

- Local-first JSON store
- No analytics SDKs
- Content capture only for URLs you visited
- Notifications are optional and local
