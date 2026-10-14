# Batterysettinginfo

A native macOS menu bar agent built with Swift, AppKit, ScreenCaptureKit, Apple Vision OCR, and an embedded `llama.cpp` inference engine running on Apple Silicon Metal acceleration.

---

## Architecture

The application runs exclusively as a background menu bar agent (`LSUIElement = YES`) with **no Dock icon** and **no main application window**.

```
Keyboard Shortcut (';' + '\'')
            │
            ▼
 ScreenCaptureKit (in-memory CGImage)
            │
            ▼
 Apple Vision OCR (VNRecognizeTextRequest)
            │
            ▼
 QuestionParser (MCQ validation: A-D, 1-4)
            │
            ▼
 Embedded llama.cpp (libLlamaBridge.dylib + Metal)
            │
            ▼
 FeedbackManager (Menu Bar UI + Caps Lock Pulse)
            │
            ▼
 Memory Cleanup (deallocate image buffers & KV cache)
```

### Module Breakdown

| Module | Location | Purpose |
|---|---|---|
| `AppDelegate.swift` | `Sources/Batterysettinginfo/` | Coordinates the end-to-end pipeline and app lifecycle |
| `MenuBarController.swift` | `Sources/Batterysettinginfo/` | Manages `NSStatusItem`, status menu, and visual result feedback |
| `ShortcutManager.swift` | `Sources/Batterysettinginfo/` | Global chord detection for `;` + `'` via `CGEventTap` |
| `ScreenCaptureService.swift` | `Sources/Batterysettinginfo/` | In-memory display capture via `ScreenCaptureKit` |
| `OCRService.swift` | `Sources/Batterysettinginfo/` | Apple Vision text recognition with bounding box sorting |
| `QuestionParser.swift` | `Sources/Batterysettinginfo/` | MCQ detection, option extraction, and non-MCQ rejection |
| `LocalInferenceEngine.swift` | `Sources/Batterysettinginfo/` | Embedded llama.cpp loader and thread-safe inference |
| `FeedbackManager.swift` | `Sources/Batterysettinginfo/` | Result delivery via menu bar icon and Caps Lock indicator |
| `AppConfiguration.swift` | `Sources/Batterysettinginfo/` | Model directory paths, shortcut keycodes, and privacy settings |
| `LlamaBridge.h / .cpp` | `Bridge/` | Native C API bridging Swift and `llama.cpp` |

---

## Requirements

- **Operating System**: macOS 13.0+ (Tested on macOS 27.0 arm64)
- **Architecture**: Apple Silicon (arm64) with Metal GPU acceleration
- **Build Tools**:
  - `clang++` / `swiftc` (Apple Clang & Swift 6.4+)
  - `cmake` (4.4+)
  - `git`

---

## Build & Development Commands

### 1. Build Application Bundle
```bash
./build.sh
```
Builds the pinned `llama.cpp` dependency (`b11620`), compiles `libLlamaBridge.dylib` with Metal acceleration, builds the Swift executable, packages `build/Batterysettinginfo.app`, sets `LSUIElement = YES`, and signs the bundle ad-hoc for local development.

### 2. Development Workflow (`dev.sh`)
```bash
# Build the application
./dev.sh build

# Launch the packaged menu bar application
./dev.sh run

# Stop the running application process
./dev.sh stop

# Run all automated tests (Parser, OCR, Bridge, Bundle, Network Audit)
./dev.sh test

# Clean build artifacts (preserves source code and user models)
./dev.sh clean

# Default workflow (build + test)
./dev.sh
```

---

## Required macOS Permissions

1. **Screen Recording** (`ScreenCaptureKit`):
   - Required to capture the screen when the shortcut is triggered.
   - Prompted on first launch or via **Menu Bar > Screen Recording: Click to Allow**.
   - System Settings: *Privacy & Security → Screen Recording*.

2. **Accessibility** (`CGEventTap`):
   - Required to detect global key events when other applications have focus.
   - Prompted via system dialog or via **Menu Bar > Accessibility: Click to Allow**.
   - System Settings: *Privacy & Security → Accessibility*.

---

## Model Installation & Configuration

The embedded engine requires **no Ollama application and no running server**. Models are loaded in-process from local `.gguf` files.

### 1. Model Location
Place any compatible `.gguf` quantized model file into:
```
~/Library/Application Support/Batterysettinginfo/models/
```
*(You can click **Open Models Directory...** directly in the menu bar menu to open this folder in Finder).*

Alternatively, set the environment variable:
```bash
export BATTERY_MODEL_PATH="/path/to/your/model.gguf"
```

### 2. Recommended Models for Local MCQ Reasoning
- **Qwen2.5-0.5B-Instruct-GGUF** (approx. 350 MB, fast and highly accurate on MCQs)
  - License: Apache 2.0
- **SmolLM-360M-Instruct-GGUF** (approx. 240 MB, minimal memory footprint)
  - License: Apache 2.0
- **Llama-3.2-1B-Instruct-GGUF** (approx. 800 MB, strong reasoning)
  - License: Llama 3.2 Community License

*Note: Model weights must be downloaded explicitly with user consent and are separate from `llama.cpp`'s MIT license.*

If no model is installed, the menu bar displays `Model: No GGUF Found (Click Open Folder)` and logs a diagnostic without crashing or pretending inference succeeded.

---

## Keyboard Shortcut & Caps Lock Feedback

### Global Shortcut (`;` + `'`)
- Primary key: Semicolon `;` (`keyCode: 41`)
- Secondary key: Quote/Apostrophe `'` (`keyCode: 39`)
- Detects simultaneous key presses across the system without stealing focus.
- Also available as a manual menu item: **Trigger Analysis (; + ')**.

### Hardware Feedback Investigation
- **Caps Lock Modifier**: The application pulses the system Caps Lock modifier state using `CGEventPost` (`keyCode: 57`) and guarantees restoration of the user's initial state.
- **Hardware LED Constraint**: On modern Apple Silicon keyboards, the physical green LED indicator is managed by keyboard microcontroller firmware and Secure Enclave anti-spoofing policies; synthetic events toggle the software modifier flag, but may not illuminate the physical LED.
- **Visual Menu Bar Feedback**: To ensure 100% reliable feedback, the menu bar status item temporarily displays the predicted answer (e.g. `✓ [ B ]`) for 4 seconds before reverting to the idle icon `🔋`.

---

## Privacy & Offline Guarantee

- **Zero Network Activity**: Static code audits verify 0 references to `URLSession`, sockets, telemetry, or remote AI APIs.
- **In-Memory Only**: Screenshots are held in memory as `CGImage` buffers and deallocated immediately after Vision text extraction. No screenshots are saved to disk.
- **Zero Query Retention**: Exam text, prompts, and inference contexts are freed immediately after answer delivery.
