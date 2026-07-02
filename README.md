# VoxrtSilero for iOS

Silero v5 voice-activity detection, running on the **VoxRT** custom on-device inference runtime.

- Current version: `v0.1.3`
- Minimum iOS: 16.0
- Architectures shipped: `arm64` (iPhone / iPad, NEON-accelerated)
- License: Apache-2.0 (Swift wrapper) · proprietary (compiled runtime, redistribution allowed via this Swift Package)

---

## What is VoxRT?

VoxRT is a from-scratch inference runtime for on-device speech models. No ONNX Runtime, no PyTorch Mobile, no LiteRT — a custom Rust core sized and tuned for streaming voice workloads on phone-class hardware.

`VoxrtSilero` is the free, open-source showcase of that runtime: a Swift Package that runs the Silero v5 VAD with state-of-the-art per-frame latency. The runtime is the product; Silero is the demo subject.

Siblings on the same runtime:

- [`VoxrtAsr`](https://github.com/VoxRT/voxrt-asr-ios) — streaming speech recognition (FastConformer 32M)
- [`VoxrtWakeWord`](https://github.com/VoxRT/voxrt-wake-word-ios) — always-on wake-phrase detection (~48 K params)

Commercial custom-phrase wake-word / keyword-spotting / domain-specific ASR models built on the same runtime live at [voxrt.com](https://voxrt.com).

## Performance

Measured at ship time, ARM64 release builds, post-warmup, RTF = wall-time-per-frame ÷ frame-duration (lower is better):

| Device                | RTF      | per-frame latency |
| --------------------- | -------- | ----------------- |
| iPhone 13 Pro Max     | **1.85%** | ~0.6 ms / 32 ms frame |

What this means: at 1.85% RTF you can run ~54 parallel VAD streams on a single core before saturating it, leaving the device idle to handle the rest of the audio pipeline (ASR, TTS, UI).

## How it compares

VAD became a commodity by 2026 — the question is **who you can actually ship in a paid mobile app** with measured numbers and a clean license:

| | **VoxrtSilero** | Picovoice Cobra | WebRTC VAD | TEN VAD |
|---|---|---|---|---|
| Underlying model | Silero v5 (MIT upstream) | proprietary | GMM (2010) | proprietary |
| Model / binary footprint | 1.2 MB model (.vxrt) | not published | < 100 KB | 320–532 KB shared lib (runtime + model bundled) |
| Mobile RTF disclosed | ✅ measured on cheap Android + iPhone | ❌ desktop Ryzen + Raspberry Pi Zero only | ❌ | ✅ vendor-measured on Android + iPhone |
| License | Apache-2.0 wrapper + proprietary runtime + MIT weights (Silero Team) | Commercial freemium (paid tier opaque) | BSD-3 | Apache-2.0 **with non-compete clause**: redistribution blocked if it could enable Agora competitors |
| Ship in a paid app | ✅ no per-deployment terms | ⚠️ requires paid commercial tier | ✅ accuracy is the 2010 floor | ❌ license clause 1 forbids it |

We don't innovate on the VAD model — Silero v5 is the upstream MIT architecture you'd already pick. What we add is a NEON-optimized Rust runtime, a stateless C ABI suitable for SDK packaging, and per-device measured RTF that other vendors don't publish.

Full sourced analysis: [voxrt.com](https://voxrt.com).

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

…and pin to **v0.1.3**.

Or in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/VoxRT/voxrt-silero-ios.git", from: "0.1.3"),
],
```

## Get the VAD model

The model weights are NOT bundled — you fetch them once from
[`voxrt-silero-models`](https://github.com/VoxRT/voxrt-silero-models/releases/tag/v0.1.3):

```
https://github.com/VoxRT/voxrt-silero-models/releases/download/v0.1.3/silero_vad.vxrt
```

SHA-256: `0fe8498c9bd1ae119bcb0c75c8481b3a8b8be0f95c14f334d469851c19054156`

You decide where it lives. Three common patterns:

- **Bundle in app resources** — drag `silero_vad.vxrt` into your Xcode project. Works offline from first launch.
- **Download on first run** — `URLSession` fetch into `FileManager.default.urls(for: .applicationSupportDirectory, ...)`. Smaller App Store binary; needs network at first launch.
- **Download on demand** — Apple's On-Demand Resources or Background Asset Downloader if you want App Store to host the file.

## Quick start

```swift
import VoxrtSilero

// 1. Resolve the bundled model URL.
guard let modelURL = Bundle.main.url(forResource: "silero_vad", withExtension: "vxrt") else {
    fatalError("silero_vad.vxrt not found in bundle")
}

// 2. Build the engine. `init(modelURL:)` memory-maps the file via
//    `Data(contentsOf:options: .mappedIfSafe)` under the hood — no
//    eager copy into RAM. One instance per audio stream.
let vad = try VoxrtSileroVadEngine(modelURL: modelURL)

// (Convenience: same as above for the default bundle + name)
//    let vad = try VoxrtSileroVadEngine.fromBundleResource()

// 3. Feed PCM (Int16, 16 kHz, mono).
let events = try vad.processPcm(samples)

for event in events {
    switch event {
    case .speechOnset(let timeMs):
        print("speech started at \(timeMs) ms")
    case .speechOffset(let timeMs):
        print("speech ended   at \(timeMs) ms")
    }
}
```

The engine owns the LSTM state internally. Call `vad.reset()` between streams (e.g. when re-arming the mic). State snapshotting for replay / fork is also supported — see `snapshotLstmState()`.

## Live microphone example

The engine is **synchronous and stateful** — no internal queue, no
delegate callbacks. You drive it from your `AVAudioEngine` tap
callback and get events back as the return value of `processPcm`.

```swift
import AVFAudio
import VoxrtSilero

// NOTE: tap callbacks fire on a real-time audio thread. Don't
// allocate heavy buffers per callback in production — pre-size +
// reuse like the snippet below.

let session = AVAudioSession.sharedInstance()
try session.setCategory(.playAndRecord, mode: .measurement, options: [])
try session.setActive(true)

let audioEngine = AVAudioEngine()
let input = audioEngine.inputNode
let hwFormat = input.outputFormat(forBus: 0)            // 44.1 / 48 kHz
let voxrtFormat = AVAudioFormat(                        // engine target
    commonFormat: .pcmFormatInt16,
    sampleRate: 16_000,
    channels: 1,
    interleaved: true,
)!
let converter = AVAudioConverter(from: hwFormat, to: voxrtFormat)!

guard let modelURL = Bundle.main.url(forResource: "silero_vad", withExtension: "vxrt") else {
    fatalError("silero_vad.vxrt missing from bundle")
}
let vad = try VoxrtSileroVadEngine(modelURL: modelURL)

// 512 samples @ 16 kHz = 32 ms — the engine's internal frame size.
// We resample mic chunks into this buffer.
let scratchCapacity: AVAudioFrameCount = 512
let voxrtBuf = AVAudioPCMBuffer(pcmFormat: voxrtFormat,
                                 frameCapacity: scratchCapacity)!

input.installTap(
    onBus: 0,
    bufferSize: 4_096,                                  // hw frames per cb
    format: hwFormat
) { hwBuf, _ in
    voxrtBuf.frameLength = 0
    var error: NSError?
    converter.convert(to: voxrtBuf, error: &error) { _, status in
        status.pointee = .haveData
        return hwBuf
    }
    if error != nil { return }
    guard let int16 = voxrtBuf.int16ChannelData?[0] else { return }
    let n = Int(voxrtBuf.frameLength)
    let samples = Array(UnsafeBufferPointer(start: int16, count: n))

    let events = try? vad.processPcm(samples)
    for event in events ?? [] {
        // Tap callbacks run off the main thread — marshal UI.
        switch event {
        case .speechOnset(let timeMs):
            DispatchQueue.main.async { print("speech started @ \(timeMs) ms") }
        case .speechOffset(let timeMs):
            DispatchQueue.main.async { print("speech ended   @ \(timeMs) ms") }
        }
    }
}

try audioEngine.start()
// ... later, on stop:
audioEngine.stop()
input.removeTap(onBus: 0)
vad.close()
```

`vad.processPcm` returns immediately with whatever VAD events
crossed the hysteresis thresholds during this buffer — often an
empty list while inside a speech segment, an onset/offset event
when the state machine transitions. UI marshalling is the
caller's job; the engine takes no opinion about your concurrency
model.

`Info.plist` must declare the microphone privacy reason:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>Used for on-device voice activity detection.</string>
```

## Audio contract

- **Sample rate:** 16 000 Hz. **No automatic resampling.** Phone mic hardware delivers 44.1 / 48 kHz to `AVAudioEngine`; convert via `AVAudioConverter` to 16 kHz Int16 mono before feeding `processPcm`. Feeding the wrong rate is the #1 source of "VAD never fires" bugs.
- **Sample format:** `Int16` PCM, mono, native endian.
- **Buffer size:** any. The engine internally segments into 32 ms frames (512 samples) with a 4 ms (64-sample) rolling context.
- **Latency:** one frame (32 ms) of inherent buffering. End-of-speech is reported with the configurable `minSilenceMs` (default 250 ms) hysteresis.

## Threading

- The engine is a **synchronous, stateful function**. It does NOT own a queue. Each `processPcm` call blocks on the calling thread for the duration of inference — typically the `AVAudioEngine` tap thread for live mic. Marshal events back to UI via `DispatchQueue.main.async` (or your concurrency framework of choice).
- One instance is **single-thread-at-a-time**. Serialise `processPcm` / `reset` / `close` against each other on a given instance.
- Between unrelated streams (e.g. re-arming the mic for a new session), call `vad.reset()` to zero the LSTM state without paying weight-load cost again. Call `vad.close()` when done.

## Permissions

iOS requires a usage-description string for microphone access. Add to your **app**'s `Info.plist`:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>Used for on-device voice activity detection.</string>
```

`AVAudioSession.requestRecordPermission(...)` triggers the user prompt the first time mic capture is initiated. Without the `Info.plist` key the app crashes with a privacy-violation exception on first request.

## Architectures roadmap

`v0.1.3` ships only `arm64` for physical devices, NEON-optimized. Simulator slices (arm64-sim + x86_64) are included for build convenience but are not part of the supported production target list.

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

- The Swift wrapper (`Sources/VoxrtSilero/`) is licensed under **Apache-2.0**. See [`LICENSE`](LICENSE).
- The compiled `VoxrtSileroNative.xcframework` (fetched by SPM from the matching GitHub Release) is proprietary VoxRT runtime code owned by Elephant Enterprises LLC, redistributable as part of this unmodified Swift Package. See [`LICENSE-BINARY`](LICENSE-BINARY) for the full terms.
- Silero VAD model weights are © Silero Team, originally MIT-licensed; the `.vxrt` encoded form retains the same license. See the [models repository](https://github.com/VoxRT/voxrt-silero-models).
- Commercial integration / custom-model packaging questions: help@voxrt.com.

## Links

- VoxRT runtime + commercial models: [voxrt.com](https://voxrt.com)
- Android counterpart: [voxrt-silero-android](https://github.com/VoxRT/voxrt-silero-android)
- VAD model weights & versions: [voxrt-silero-models](https://github.com/VoxRT/voxrt-silero-models)
- Streaming ASR (iOS): [voxrt-asr-ios](https://github.com/VoxRT/voxrt-asr-ios) · [models](https://github.com/VoxRT/voxrt-asr-models)
- Wake-word (iOS): [voxrt-wake-word-ios](https://github.com/VoxRT/voxrt-wake-word-ios) · [models](https://github.com/VoxRT/voxrt-wake-word-models)
- Bugs / questions: open an issue on this repo
