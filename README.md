# VoxrtSilero for iOS

Silero v5 voice-activity detection, running on the **VoxRT** custom on-device inference runtime.

- Current version: `v0.1.1`
- Minimum iOS: 16.0
- Architectures shipped: `arm64` (iPhone / iPad, NEON-accelerated)
- License: Apache-2.0 (Swift wrapper) · proprietary (compiled runtime, redistribution allowed via this Swift Package)

---

## What is VoxRT?

VoxRT is a from-scratch inference runtime for on-device speech models. No ONNX Runtime, no PyTorch Mobile, no LiteRT — a custom Rust core sized and tuned for streaming voice workloads on phone-class hardware.

`VoxrtSilero` is the free, open-source showcase of that runtime: a Swift Package that runs the Silero v5 VAD with state-of-the-art per-frame latency. The runtime is the product; Silero is the demo subject.

Commercial wake-word / keyword-spotting / phrase-recognition models built on the same runtime live at [voxrt.com](https://voxrt.com).

## Performance

Measured at ship time, ARM64 release builds, post-warmup, RTF = wall-time-per-frame ÷ frame-duration (lower is better):

| Device                | RTF      | per-frame latency |
| --------------------- | -------- | ----------------- |
| iPhone 13 Pro Max     | **1.85%** | ~0.6 ms / 32 ms frame |

What this means: at 1.85% RTF you can run ~54 parallel VAD streams on a single core before saturating it, leaving the device idle to handle the rest of the audio pipeline (ASR, TTS, UI).

## Binary footprint

- Swift wrapper source: ~17 KB total (`.swift` files included in your app's compile pass)
- `VoxrtSileroNative.xcframework` (compressed): ~500 KB device slice
- Silero VAD weights `silero_vad.vxrt`: 1.2 MB (downloaded separately, see below)

Net app-size impact: ~1.7 MB.

## Install

In Xcode: **File → Add Package Dependencies →** paste:

```
https://github.com/VoxRT/voxrt-silero-ios
```

…and pin to **v0.1.1**.

Or in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/VoxRT/voxrt-silero-ios.git", from: "0.1.1"),
],
```

## Get the VAD model

The model weights are NOT bundled — you fetch them once from
[`voxrt-silero-models`](https://github.com/VoxRT/voxrt-silero-models/releases/tag/v0.1.1):

```
https://github.com/VoxRT/voxrt-silero-models/releases/download/v0.1.1/silero_vad.vxrt
```

SHA-256: `0fe8498c9bd1ae119bcb0c75c8481b3a8b8be0f95c14f334d469851c19054156`

You decide where it lives. Three common patterns:

- **Bundle in app resources** — drag `silero_vad.vxrt` into your Xcode project. Works offline from first launch.
- **Download on first run** — `URLSession` fetch into `FileManager.default.urls(for: .applicationSupportDirectory, ...)`. Smaller App Store binary; needs network at first launch.
- **Download on demand** — Apple's On-Demand Resources or Background Asset Downloader if you want App Store to host the file.

## Quick start

```swift
import VoxrtSilero

// 1. Load the model bytes (however you obtained them).
guard let url = Bundle.main.url(forResource: "silero_vad", withExtension: "vxrt"),
      let modelBytes = try? Data(contentsOf: url) else {
    fatalError("silero_vad.vxrt not found")
}

// 2. Spin up an engine. One per audio stream.
let vad = try VoxrtSileroVad(modelBytes: modelBytes)

// 3. Feed PCM (Int16, 16 kHz, mono).
let events = try vad.processPcm(samples)

for event in events {
    switch event.kind {
    case .speechStart: print("speech started at \(event.timestampMs) ms")
    case .speechEnd:   print("speech ended   at \(event.timestampMs) ms")
    }
}
```

The engine owns the LSTM state internally. Call `vad.reset()` between streams (e.g. when re-arming the mic). State snapshotting for replay / fork is also supported — see `snapshotLstmState()`.

## Audio contract

- **Sample rate:** 16 000 Hz
- **Sample format:** `Int16` PCM, mono, native endian
- **Buffer size:** any. The engine internally segments into 32 ms frames (512 samples) with a 4 ms (64-sample) rolling context.
- **Latency:** one frame (32 ms) of inherent buffering. End-of-speech is reported with the configurable `minSilenceMs` (default 250 ms) hysteresis.

## Architectures roadmap

`v0.1.1` ships only `arm64` for physical devices, NEON-optimized. Simulator slices (arm64-sim + x86_64) are included for build convenience but are not part of the supported production target list.

| Target                       | Status     |
| ---------------------------- | ---------- |
| iOS arm64 (device)           | ✅ Shipped  |
| iOS arm64 simulator          | ✅ Shipped (build-time only) |
| iOS x86_64 simulator         | ✅ Shipped (build-time only) |
| macOS arm64                  | 🟡 Coming soon |
| macOS x86_64 (AVX)           | 🟡 Coming soon |
| visionOS / tvOS / watchOS    | ☁️ On request |

## Project layout

```
voxrt-silero-ios/
├── Package.swift                 # SPM manifest (binaryTarget URL + checksum)
├── Sources/VoxrtSilero/          # Idiomatic Swift wrapper (open, Apache-2.0)
│   └── VoxrtSilero.swift
└── README.md                     # this file
```

The compiled `VoxrtSileroNative.xcframework` is downloaded automatically by SPM from this version's GitHub Release — it is not in the repo.

## License

- The Swift wrapper (`Sources/VoxrtSilero/`) is licensed under **Apache-2.0**.
- The compiled `VoxrtSileroNative.xcframework` is proprietary VoxRT runtime code, redistributed for use **with the unmodified VoxrtSilero Swift Package**. See `LICENSE-BINARY` (in the binary distribution) for the full terms.
- Silero VAD model weights are © Silero Team, originally MIT-licensed; the `.vxrt` encoded form retains the same license. See the [models repository](https://github.com/VoxRT/voxrt-silero-models).

## Links

- VoxRT runtime + commercial models: [voxrt.com](https://voxrt.com)
- Android counterpart: [voxrt-silero-android](https://github.com/VoxRT/voxrt-silero-android)
- VAD model weights & versions: [voxrt-silero-models](https://github.com/VoxRT/voxrt-silero-models)
- Bugs / questions: open an issue on this repo
