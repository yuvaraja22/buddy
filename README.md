# Buddy

**Offline voice-first workout tracker and local AI gym coach for iPhone (iOS 17+).**

Speak naturally between sets — *"leg extension 3 sets 15 reps"*, *"bench press 60 kg 3 sets 10 reps"*, *"drop set 30 kg 12 reps"*, or *"change last set to 12 reps"* — and Buddy logs structured sets locally with zero cloud servers, subscriptions, or accounts.

---

## Features

- **1-Tap Offline Voice Logging**: Built on **Apple On-Device Speech** (`SFSpeechRecognizer`, `requiresOnDeviceRecognition = true`) with **0 MB download**, live streaming captions while speaking, gym vocabulary biasing across 105 exercises, and an Accent/Locale picker (`Auto`, `English (India)`, `English (US)`, `English (UK)`, `English (Australia)`, `English (Canada)`). Record from the floating mic button, Home Screen widgets, Lock Screen widgets, or the active workout Live Activity (`buddy://record`).
- **YouTube + Uber OLED Monochrome UI**: Pitch-black `#000000` canvas, matte charcoal surfaces (`#141414`), crisp white/black high-contrast controls, floating pill bottom navigation paired with a morphing Mic FAB, Uber-style command bar & circular Quick Start split tiles (`Push`, `Pull`, `Legs`, `Open`), and YouTube-style 16:9 dark artwork exercise & session rows (with Dark / Light / System appearance toggle in Settings).
- **Smart Set Expansion & Undo**: Commands like *"leg extension 3 sets 15 reps"* expand into 3 numbered `LoggedSet` rows under one exercise card, with directly tappable inline set chips, expandable rows, and 1-tap Undo.
- **Widgets & Live Activities**:
  - **Home Screen** (Small, Medium, Large): Streak counter, live session timer, 7-day monochrome consistency/volume bar chart, today's exercises, and crisp monochrome Record CTA.
  - **Lock Screen** (Circular, Rectangular, Inline): Weekly goal progress ring with centered mic icon, today's set/volume status, and streak ticker.
  - **Dynamic Island & Lock Screen Live Activity**: Ticking workout timer, live set & volume counters, last logged exercise, and 1-tap **Voice Log** pill.
- **Trends & Progression**: Workout streaks, weekly goal tracking, monochrome 12-week activity heatmap, volume timelines, and per-exercise strength progression with YouTube-style filter chips.
- **Local AI Gym Coach**: Ask training questions grounded in your on-device SwiftData workout history.
- **SideStore-Ready App Group Sync**: Dynamically reads `embedded.mobileprovision` at runtime so `Buddy` and `BuddyWidgets` stay synced even when SideStore/AltStore remaps `group.com.yuvaraja.buddy` with a free Apple ID Team suffix.

---

## iPhone 15 Plus Offline Architecture

Buddy is tuned for Apple A16 Bionic + 6 GB RAM (iPhone 15 Plus) and runs 100% locally:

| Layer | Technology | Role |
| --- | --- | --- |
| **Speech-to-Text** | **Apple On-Device Speech** (`Speech` framework) | 0 MB / 0 RAM offline live-caption gym transcription with exercise vocabulary hints; audio never leaves the iPhone |
| **Intent Parsing & Coach** | **Qwen2.5-1.5B** (`LLM.swift` / llama.cpp Metal) | Structured JSON workout command extraction & offline coaching |
| **Instant Fallback Parser** | `RuleBasedWorkoutParser` + `ExerciseCatalog` | Zero-latency deterministic parser for common set commands, edits, and exercise aliases (works immediately before downloading Qwen) |
| **Persistence** | **SwiftData** + Shared App Group JSON Snapshot | Local relational workout database + atomic `widget_snapshot.json` for WidgetKit |
| **UI & System Extensions** | **SwiftUI**, **WidgetKit**, **ActivityKit** | OLED monochrome dark-first design (`#000000` / `#141414` / `#FFFFFF`), sharp sans-serif tabular numerals, Dark/Light/System toggle |

---

## Installing via SideStore

Buddy is built automatically in GitHub Actions (`.github/workflows/build-ipa.yml`) into an unsigned `Buddy.ipa` ready for SideStore re-signing.

### Option A: Private Repository (GitHub Actions Artifact or Release)

1. Open the repository's **Actions** tab (latest successful **Build & Package Buddy IPA** run) or **Releases** page on your iPhone.
2. Download the **`Buddy-IPA`** artifact (unzip if downloaded from Actions) or **`Buddy.ipa`** directly from a tagged Release.
3. Open **SideStore** on your iPhone, go to **My Apps**, tap **`+`**, and select `Buddy.ipa`.
4. When prompted about App Extensions (`BuddyWidgets`), choose **Keep App Extensions** so Home Screen widgets, Lock Screen widgets, and Dynamic Island Live Activities remain active.
5. Note: A free Apple ID allows up to **3 active sideloaded apps** and **10 App IDs per 7 days** (`Buddy` uses 1 active app slot and 2 App IDs: `Buddy` + `BuddyWidgets`).

### Option B: Public Repository (SideStore `apps.json` Source Feed)

If the repository is public and has a published tag release (e.g., `v1.0.0`):

1. Open **SideStore** → **Sources** → **`+`**.
2. Add the latest release source URL:
   ```
   https://github.com/yuvaraja22/buddy/releases/latest/download/apps.json
   ```
3. Tap **Buddy** and install with one tap. Future `v*` tag releases automatically publish an updated `Buddy.ipa` (with matching version metadata) and `apps.json` feed.

---

## First-Run Setup

1. Launch **Buddy** and allow **Microphone** and **Speech Recognition** when prompted — offline voice logging works right away with **Apple On-Device Speech** (0 MB download) and the built-in **Instant Parser**.
2. *(Optional, recommended over Wi-Fi)* Open **Settings → Local LLM (llama.cpp)** (or follow the first-run prompt) to download **Qwen2.5-1.5B (Q4)** (~1.05 GB) — or lighter **Qwen2.5-0.5B** (~490 MB) — to unlock the offline **AI Gym Coach** and richer natural-language voice parsing.
3. Once cached locally on your iPhone, Buddy works **100% offline in Airplane Mode** inside the gym.

---

## Development & CI

```bash
# Generate Buddy.xcodeproj from project.yml (macOS + Xcode 16+)
brew install xcodegen
xcodegen generate

# Run unit tests
xcodebuild test -project Buddy.xcodeproj -scheme Buddy \
  -destination 'platform=iOS Simulator,name=iPhone 15 Plus' \
  CODE_SIGNING_ALLOWED=NO
```

Push a version tag (e.g., `v1.0.0`) to trigger GitHub Actions to run all unit tests, archive and verify `Buddy.ipa`, generate updated `apps.json` metadata, and publish a GitHub Release.