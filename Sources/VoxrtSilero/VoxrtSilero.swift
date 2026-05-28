// VoxrtSilero.swift — idiomatic Swift wrapper over the stateless
// `voxrt_silero_*` C ABI (ADR-0020 + the VoxRT rename in ADR-0021
// + the stateless redesign in ADR-0022).
//
// Per ADR-0022 the closed Rust binary does only runtime execution.
// Everything else — PCM buffering, rolling STFT context, LSTM state
// management, hysteresis state machine, event emission — lives here
// in this open Swift wrapper. Contributors who want to experiment
// with anti-drift, partial state reset, or checkpoint patterns land
// their changes in this file.
//
// Threading: per-instance, **not** thread-safe. Serialise
// `processPcm` / `reset` / `close` against each other on a given
// `VoxrtSileroVadEngine` (matches the Kotlin `VoxrtSileroVadEngine`
// contract one-to-one across platforms).

import Foundation
import VoxrtSileroNative

// ─── Public types ─────────────────────────────────────────────────────────

/// Errors raised by `VoxrtSileroVadEngine`. Each case maps 1:1 to a
/// `VOXRT_ERR_*` status code from the C API, plus a couple of
/// Swift-side conditions.
public enum VoxrtSileroError: Error, Equatable, CustomStringConvertible {
    /// Null pointer or other invalid argument passed across the FFI.
    case invalidArgument
    /// Handle is null or already destroyed.
    case invalidHandle
    /// `.vxrt` bytes failed to deserialise.
    case modelDeserialize
    /// Loaded model doesn't match the expected shape (wrong model
    /// for this entry point).
    case modelShape
    /// Out-of-memory while building the session.
    case oom
    /// Caught Rust panic or other unexpected internal state.
    case internalError
    /// `Bundle.url(forResource:withExtension:)` returned `nil` for
    /// the requested name + extension. Typical fix: confirm the
    /// `.vxrt` is in the app target's *Copy Bundle Resources* build
    /// phase, with the exact filename `name.ext`.
    case resourceNotFound(name: String, extension: String, bundle: String)
    /// Unrecognised status code (forward-compat for future error
    /// classes the SDK may add).
    case unknown(Int32)

    fileprivate init(_ status: voxrt_status_t) {
        switch status {
        case VOXRT_ERR_INVALID_ARG:        self = .invalidArgument
        case VOXRT_ERR_INVALID_HANDLE:     self = .invalidHandle
        case VOXRT_ERR_MODEL_DESERIALIZE:  self = .modelDeserialize
        case VOXRT_ERR_MODEL_SHAPE:        self = .modelShape
        case VOXRT_ERR_OOM:                self = .oom
        case VOXRT_ERR_INTERNAL:           self = .internalError
        default:                           self = .unknown(status)
        }
    }

    public var description: String {
        switch self {
        case .invalidArgument:
            return "invalidArgument (null pointer or bad length crossed the FFI boundary)"
        case .invalidHandle:
            return "invalidHandle (closed or never-built session)"
        case .modelDeserialize:
            return "modelDeserialize (.vxrt bytes failed to parse)"
        case .modelShape:
            return "modelShape (model loaded but doesn't match the expected Silero v5 graph)"
        case .oom:
            return "oom (allocation failure inside the runtime)"
        case .internalError:
            return "internalError (unexpected condition / caught Rust panic)"
        case .resourceNotFound(let name, let ext, let bundle):
            return "resourceNotFound — '\(name).\(ext)' is not in \(bundle). "
                + "Confirm the file is included in the app target's "
                + "*Copy Bundle Resources* build phase."
        case .unknown(let code):
            return "unknown(\(code))"
        }
    }
}

/// Discrete events emitted by the VAD state machine. `timeMs` is an
/// absolute timestamp from the engine's creation (or its last
/// `reset`), measured in milliseconds.
public enum VadEvent: Equatable {
    case speechOnset(timeMs: UInt64)
    case speechOffset(timeMs: UInt64)
}

/// Streaming hysteresis configuration. Defaults match Silero's
/// published recommendations (`onset 0.5 / offset 0.35 /
/// min-silence 100 ms`); raise `onsetThreshold` to suppress
/// transient false-positives on noisy capture, lower it for
/// snappier onset on quiet speakers.
public struct VoxrtSileroConfig: Equatable {
    public var onsetThreshold: Float
    public var offsetThreshold: Float
    public var minSilenceMs: UInt32

    public init(
        onsetThreshold: Float = 0.5,
        offsetThreshold: Float = 0.35,
        minSilenceMs: UInt32 = 100
    ) {
        self.onsetThreshold = onsetThreshold
        self.offsetThreshold = offsetThreshold
        self.minSilenceMs = minSilenceMs
    }
}

// ─── Version helpers ──────────────────────────────────────────────────────

/// SDK version string (e.g. `"0.0.1"`).
public func voxrtVersion() -> String {
    guard let pointer = voxrt_version() else { return "" }
    return String(cString: pointer)
}

/// Packed `(major, minor)` ABI version reported by the native side.
public struct VoxrtABIVersion: Equatable {
    public let major: UInt16
    public let minor: UInt16
}

public func voxrtABIVersion() -> VoxrtABIVersion {
    let raw = voxrt_abi_version()
    return VoxrtABIVersion(
        major: UInt16((raw >> 16) & 0xFFFF),
        minor: UInt16(raw & 0xFFFF)
    )
}

// ─── The wrapper ──────────────────────────────────────────────────────────

/// Streaming Silero v5 VAD.
///
/// Build one per audio stream; reuse across calls to `processPcm`.
/// Call `reset()` when starting a new logical stream (e.g. session
/// boundary in a meeting app) so the LSTM state doesn't bleed across.
///
/// All streaming state — PCM accumulator, rolling 64-sample STFT
/// context, LSTM `h`/`c`, hysteresis machine, time counter — lives
/// in this class, per ADR-0022. The closed Rust binary handles only
/// model execution.
public final class VoxrtSileroVadEngine {

    // ─── Native handle ─────────────────────────────────────────────────
    //
    // Stored as `OpaquePointer` because Swift's clang importer maps
    // forward-declared opaque C structs (`typedef struct voxrt_silero_t
    // voxrt_silero_t;`) to an anonymous opaque type. The handle is
    // still a real `voxrt_silero_t *` at the ABI level.
    private var handle: OpaquePointer?

    // ─── Streaming state (owned by Swift per ADR-0022) ────────────────
    //
    // LSTM state — h[128] + c[128] = 256 f32 in a flat buffer that we
    // pass to the C ABI as a pointer to `voxrt_silero_model_state_t`.
    // Layout matches the C struct (repr(C)).
    private var lstmState: [Float]
    private static let lstmStateFloats: Int = 2 * 128

    private var config: VoxrtSileroConfig

    // PCM accumulator: caller's audio gets concatenated here until
    // we have `windowSamples` (512) fresh samples to run inference on.
    private var pendingPcm: [Int16] = []

    // Rolling 64-sample tail of the most recent inference window —
    // spliced in front of the next window so the model sees the
    // [context | new] = 576-sample input it was exported with.
    private var rollingContext: [Int16]

    // Reusable scratch for the assembled [context | window] input.
    private var inferInput: [Int16]

    /// Hysteresis: current speech / silence state.
    private var inSpeech: Bool = false
    /// Timestamp of the first below-offset chunk in the current
    /// silence run; `nil` when we're not currently tracking an
    /// offset candidate.
    private var candidateOffsetMs: UInt64? = nil
    /// Monotonic chunk counter (each successful inference == one
    /// chunk == 32 ms of audio).
    private var chunkCount: UInt64 = 0

    // ─── Constants pulled from the C ABI (single source of truth) ─────
    private static let windowSamples: Int = voxrt_silero_window_samples()
    private static let contextSamples: Int = voxrt_silero_context_samples()
    private static let inputSamples: Int = voxrt_silero_input_samples()
    private static let msPerChunk: UInt64 =
        UInt64(VoxrtSileroVadEngine.windowSamples) * 1000 / 16_000

    // ─── Construction ─────────────────────────────────────────────────

    /// Build a session with the engine's default hysteresis
    /// (`onset 0.5 / offset 0.35 / min-silence 100 ms`).
    public convenience init(modelBytes: Data) throws {
        try self.init(modelBytes: modelBytes, config: VoxrtSileroConfig())
    }

    /// Build a session with caller-supplied hysteresis.
    public init(modelBytes: Data, config: VoxrtSileroConfig) throws {
        var handle: OpaquePointer?
        let status = modelBytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> voxrt_status_t in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                return VOXRT_ERR_INVALID_ARG
            }
            return voxrt_silero_create(base, modelBytes.count, &handle)
        }
        guard status == VOXRT_OK, let resolved = handle else {
            throw VoxrtSileroError(status)
        }
        self.handle = resolved
        self.config = config
        self.lstmState = [Float](repeating: 0, count: VoxrtSileroVadEngine.lstmStateFloats)
        self.rollingContext = [Int16](repeating: 0, count: VoxrtSileroVadEngine.contextSamples)
        self.inferInput = [Int16](repeating: 0, count: VoxrtSileroVadEngine.inputSamples)
    }

    /// Load the `.vxrt` model directly from a `URL`, memory-mapping
    /// the file via `Data(contentsOf:options: .mappedIfSafe)`. This
    /// is the recommended path for bundled assets and downloaded
    /// files on iOS — avoids reading the whole file into RAM and is
    /// the iOS counterpart of the Android `fromAssetFd(...)` factory.
    ///
    /// The `options` parameter defaults to `.mappedIfSafe` which lets
    /// the OS demand-page the file. Pass `[]` if you specifically
    /// need an eager copy (rare; only useful for tiny files on
    /// platforms where mmap is undesirable).
    public convenience init(
        modelURL url: URL,
        config: VoxrtSileroConfig = VoxrtSileroConfig(),
        readingOptions options: Data.ReadingOptions = .mappedIfSafe
    ) throws {
        let data = try Data(contentsOf: url, options: options)
        try self.init(modelBytes: data, config: config)
    }

    /// Load model bytes from the SDK's bundle. Convenience wrapper
    /// around `init(modelURL:config:)` that resolves the bundled
    /// `.vxrt` resource by name + extension first.
    public static func fromBundleResource(
        named name: String = "silero_vad",
        extension ext: String = "vxrt",
        in bundle: Bundle = .main,
        config: VoxrtSileroConfig = VoxrtSileroConfig()
    ) throws -> VoxrtSileroVadEngine {
        guard let url = bundle.url(forResource: name, withExtension: ext) else {
            throw VoxrtSileroError.resourceNotFound(
                name: name,
                extension: ext,
                bundle: bundle.bundleIdentifier ?? bundle.bundlePath
            )
        }
        return try VoxrtSileroVadEngine(modelURL: url, config: config)
    }

    deinit {
        if let handle = handle {
            voxrt_silero_destroy(handle)
        }
    }

    // ─── Public API ───────────────────────────────────────────────────

    /// Push 16 kHz mono i16 PCM into the session and return any
    /// events triggered by the new audio. Caller may pass any
    /// number of samples; the wrapper buffers up to the model's
    /// 512-sample window internally.
    public func processPcm(_ pcm: [Int16]) throws -> [VadEvent] {
        guard let handle = handle else { throw VoxrtSileroError.invalidHandle }

        var events: [VadEvent] = []
        var cursor = 0

        while cursor < pcm.count {
            // Top up `pendingPcm` to one window's worth.
            let need = VoxrtSileroVadEngine.windowSamples - pendingPcm.count
            let take = min(need, pcm.count - cursor)
            pendingPcm.append(contentsOf: pcm[cursor ..< cursor + take])
            cursor += take

            if pendingPcm.count < VoxrtSileroVadEngine.windowSamples {
                break // not enough audio yet
            }

            // Assemble the [context_64 | window_512] inference input.
            inferInput.replaceSubrange(
                0 ..< VoxrtSileroVadEngine.contextSamples,
                with: rollingContext
            )
            inferInput.replaceSubrange(
                VoxrtSileroVadEngine.contextSamples ..< VoxrtSileroVadEngine.inputSamples,
                with: pendingPcm
            )
            // Save the trailing 64 of this window as next call's context.
            rollingContext = Array(
                pendingPcm[(VoxrtSileroVadEngine.windowSamples - VoxrtSileroVadEngine.contextSamples) ..<
                    VoxrtSileroVadEngine.windowSamples]
            )
            pendingPcm.removeAll(keepingCapacity: true)

            // Call the C ABI: takes input, mutates lstmState, returns prob.
            let prob = try inferOneWindow(handle: handle)

            chunkCount += 1
            let timeMs = chunkCount * VoxrtSileroVadEngine.msPerChunk
            applyHysteresis(prob: prob, timeMs: timeMs, events: &events)
        }

        return events
    }

    /// Reset all streaming state (PCM accumulator, rolling context,
    /// LSTM, hysteresis, chunk counter). Timestamps restart from 0.
    public func reset() {
        pendingPcm.removeAll(keepingCapacity: true)
        for i in 0 ..< rollingContext.count { rollingContext[i] = 0 }
        for i in 0 ..< lstmState.count { lstmState[i] = 0 }
        inSpeech = false
        candidateOffsetMs = nil
        chunkCount = 0
    }

    /// Explicit teardown. Idempotent. Class also calls this on `deinit`.
    public func close() {
        if let handle = handle {
            voxrt_silero_destroy(handle)
            self.handle = nil
        }
    }

    // ─── State-management knobs (open per ADR-0022 for experiments) ───

    /// Snapshot the LSTM `h` / `c` state. Returns a flat
    /// `[Float]` of length 256 (`h[0..128] + c[128..256]`). Use
    /// for checkpoint inference, anti-drift recovery, etc.
    public func snapshotLstmState() -> [Float] {
        return lstmState
    }

    /// Restore a previously-snapshotted LSTM state. The caller is
    /// responsible for matching length (256 floats).
    public func restoreLstmState(_ snapshot: [Float]) {
        guard snapshot.count == VoxrtSileroVadEngine.lstmStateFloats else { return }
        lstmState = snapshot
    }

    /// Zero just the LSTM state without touching the PCM
    /// accumulator / rolling context / hysteresis. Useful as a
    /// "soft reset" on long silence to fight Silero v5's known
    /// long-stream drift (see `silero_v5_long_stream_drift.md`).
    public func zeroLstmState() {
        for i in 0 ..< lstmState.count { lstmState[i] = 0 }
    }

    // ─── Internals ────────────────────────────────────────────────────

    /// One Silero inference. `inferInput` and `lstmState` must
    /// already be populated. Returns the per-window speech prob.
    private func inferOneWindow(handle: OpaquePointer) throws -> Float {
        var prob: Float = 0
        let status: voxrt_status_t = inferInput.withUnsafeBufferPointer { inBuf -> voxrt_status_t in
            return lstmState.withUnsafeMutableBufferPointer { (stateBuf: inout UnsafeMutableBufferPointer<Float>) -> voxrt_status_t in
                let statePtr = stateBuf.baseAddress!.withMemoryRebound(
                    to: voxrt_silero_model_state_t.self, capacity: 1
                ) { $0 }
                return voxrt_silero_infer(
                    handle,
                    inBuf.baseAddress,
                    inBuf.count,
                    statePtr,
                    &prob
                )
            }
        }
        guard status == VOXRT_OK else {
            throw VoxrtSileroError(status)
        }
        return prob
    }

    /// Single-step hysteresis. Same algorithm the runtime used to
    /// run internally before ADR-0022 moved it out here.
    private func applyHysteresis(prob: Float, timeMs: UInt64, events: inout [VadEvent]) {
        if !inSpeech {
            if prob >= config.onsetThreshold {
                inSpeech = true
                candidateOffsetMs = nil
                events.append(.speechOnset(timeMs: timeMs))
            }
        } else if prob >= config.onsetThreshold {
            // Back above onset — cancel any pending offset candidate.
            candidateOffsetMs = nil
        } else if prob < config.offsetThreshold {
            if candidateOffsetMs == nil {
                candidateOffsetMs = timeMs
            }
            if let started = candidateOffsetMs,
               timeMs - started >= UInt64(config.minSilenceMs) {
                inSpeech = false
                candidateOffsetMs = nil
                events.append(.speechOffset(timeMs: timeMs))
            }
        }
        // Between offset and onset (the hysteresis dead-zone) — hold
        // state, don't reset candidateOffsetMs.
    }
}

// ─── Backwards-compatibility alias ────────────────────────────────────────
//
// v0.1.0 / v0.1.1 published the class as `VoxrtSileroVad`. v0.1.2
// renames it to `VoxrtSileroVadEngine` so the iOS surface matches
// the Kotlin `VoxrtSileroVadEngine` 1:1 (cross-platform call sites
// look identical). Existing iOS callers keep compiling — the
// deprecated typealias yields a one-shot warning that points at
// the new name.

@available(*, deprecated, renamed: "VoxrtSileroVadEngine",
           message: "Renamed in v0.1.2 to match the Kotlin VoxrtSileroVadEngine. Update the type reference; behaviour is identical.")
public typealias VoxrtSileroVad = VoxrtSileroVadEngine
