# Buddy

**Offline voice-first workout tracker and local AI gym coach for iPhone (iOS 17+).**

Speak naturally between sets — *"leg extension 3 sets 15 reps"*, *"bench press 60 kg 3 sets 10 reps"*, *"drop set 30 kg 12 reps"*, or *"change last set to 12 reps"* — and Buddy logs structured sets locally with zero cloud servers, subscriptions, or accounts.

---

## Features

- **1-Tap Voice Logging**: Record directly from the app, Home Screen widgets, Lock Screen widgets, or the active workout Live Activity (`buddy://record`).
- **Smart Set Expansion & Undo**: Commands like *"leg extension 3 sets 15 reps"* expand into 3 numbered `LoggedSet` rows under one exercise card, with instant inline editing and 1-tap Undo.
- **Widgets & Live Activities**:
  - **Home Screen** (Small, Medium, Large): Streak counter, live session timer, 7-day consistency/volume bar chart, today's exercises, and cobalt Record CTA.
  - **Lock Screen** (Circular, Rectangular, Inline): Weekly goal progress ring with centered mic icon, today's set/volume status, and streak ticker.
  - **Dynamic Island & Lock Screen Live Activity**: Ticking workout timer, live set & volume counters, last logged exercise, and 1-tap **Voice Log** pill.
- **Trends & Progression**: Workout streaks, weekly goal tracking, activity heatmaps, volume timelines, and per-exercise strength progression.
- **Local AI Gym Coach**: Ask training questions grounded in your on-device SwiftData workout history.
- **SideStore-Ready App Group Sync**: Dynamically reads `embedded.mobileprovision` at runtime so `Buddy` and `BuddyWidgets` stay synced even when SideStore/AltStore remaps `group.com.yuvaraja.buddy` with a free Apple ID Team suffix.

---

## iPhone 15 Plus Offline Architecture

Buddy is tuned for Apple A16 Bionic + 6 GB RAM (iPhone 15 Plus) and runs 100% locally:

| Layer | Technology | Role |
| --- | --- | --- |
| **Speech-to-Text** | **WhisperKit** (CoreML / Neural Engine) | On-device gym audio transcription; audio never leaves the iPhone |
| **Intent Parsing & Coach** | **Qwen2.5-1.5B** (`LLM.swift` / llama.cpp Metal) | Structured JSON workout command extraction & offline coaching |
| **Instant Fallback Parser** | `RuleBasedWorkoutParser` + `ExerciseCatalog` | Zero-latency deterministic parser for common set commands, edits, and exercise aliases (works even before model download) |
| **Persistence** | **SwiftData** + Shared App Group JSON Snapshot | Local relational workout database + atomic `widget_snapshot.json` for WidgetKit |
| **UI & System Extensions** | **SwiftUI**, **WidgetKit**, **ActivityKit** | Adaptive Light/Dark cobalt design (`#0A66FF` / `#3B82F6`), rounded tabular numerals |

---

## Installing via SideStore

Buddy is built automatically in GitHub Actions (`.github/workflows/build-ipa.yml`) into an unsigned `Buddy.ipa` ready for SideStore re-signing.

### Option A: Private Repository (GitHub Actions Artifact or Release)

1. Open the repository's **Actions** tab (latest successful **Build & Package Buddy IPA** run) or **Releases** page on your iPhone.
2. Download the **`Buddy-IPA`** artifact (unzip if downloaded from Actions) or **`Buddy.ipa`** directly from a tagged Release.
3. Open **SideStore** on your iPhone, go to **My Apps**, tap **`+`**, and select `Buddy.ipa`.
4. When prompted about App Extensions (`BuddyWidgets`), choose **Keep App Extensions** so Home Screen widgets, Lock Screen widgets, and Dynamic Island Live Activities remain active.
5. Note: A free Apple ID allows up to **3 active App IDs** (`Buddy` + `BuddyWidgets` = 2 App IDs, leaving 1 slot free for SideStore).

### Option B: Public Repository (SideStore `apps.json` Source Feed)

If the repository is public and has a published tag release (e.g., `v1.0.0`):

1. Open **SideStore** → **Sources** → **`+`**.
2. Add the source URL:
   ```
   https://raw.githubusercontent.com/yuvaraja22/buddy/main/apps.json
   ```
3. Tap **Buddy** and install with one tap. Future `v*` tag releases automatically publish an updated `Buddy.ipa` and `apps.json` metadata.

---

## First-Run Wi-Fi Model Download

1. Launch **Buddy** while connected to **Wi-Fi** (keep the app open on screen during the initial download).
2. Open **Settings → Offline AI Models** (or follow the first-run prompt) to download:
   - **WhisperKit** speech model (CoreML weights)
   - **Qwen2.5-1.5B** quantized GGUF model (~1 GB)
3. Once downloaded and cached locally on your iPhone, Buddy works **100% offline in Airplane Mode** inside the gym.
4. Even before downloading Qwen2.5-1.5B, the built-in **Instant Parser** handles standard voice and text commands immediately.

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