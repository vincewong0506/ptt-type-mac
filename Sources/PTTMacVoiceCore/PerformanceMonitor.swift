import AppKit
import Combine
import Darwin
import Metal
import OSLog

// Live readout of this process's memory + CPU + Metal GPU footprint.
// AppModel owns one instance; the Settings "Performance" panel observes
// it. Sampling is tied to NSApplication.isActive — when the user has
// the app focused we sample once a second, when they switch away we
// stop entirely so a backgrounded App doesn't burn cycles updating
// numbers no one is looking at.
//
// Apple Silicon is unified-memory: GPU allocations made by MLX/Metal
// are already accounted for inside this process's `phys_footprint`.
// The `gpuAllocatedBytes` reading from MTLDevice is a *system-wide*
// number (every process's Metal allocations on this device combined),
// useful as context — the delta when our app loads / unloads the ASR
// model is a decent proxy for "how much GPU memory MLX is using" — but
// not a per-app figure. The Performance panel UI labels it as such.
@MainActor
final class PerformanceMonitor: ObservableObject {
    @Published private(set) var memoryFootprintBytes: UInt64 = 0
    @Published private(set) var cpuPercent: Double = 0
    @Published private(set) var gpuAllocatedBytes: UInt64 = 0
    @Published private(set) var isSampling: Bool = false

    private static let sampleInterval: TimeInterval = 1.0
    private let metalDevice = MTLCreateSystemDefaultDevice()
    private var sampleTimer: Timer?
    private var lastCPUTimeNs: UInt64?
    private var lastSampleAt: Date?
    private var becameActiveToken: NSObjectProtocol?
    private var resignedActiveToken: NSObjectProtocol?
    private let logger = Logger(subsystem: "com.pttcoding.PTTVoice", category: "Perf")

    init() {
        becameActiveToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.startSampling() }
        }
        resignedActiveToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.stopSampling() }
        }
        if NSApplication.shared.isActive {
            startSampling()
        }
    }

    deinit {
        if let token = becameActiveToken {
            NotificationCenter.default.removeObserver(token)
        }
        if let token = resignedActiveToken {
            NotificationCenter.default.removeObserver(token)
        }
    }

    // MARK: - Sampling lifecycle

    private func startSampling() {
        guard sampleTimer == nil else { return }
        // First sample is sync so the UI gets non-zero numbers immediately.
        // CPU% will be 0 on the first sample (no delta yet) — that's fine.
        sample()
        let timer = Timer.scheduledTimer(
            withTimeInterval: Self.sampleInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        sampleTimer = timer
        isSampling = true
        logger.debug("Sampling started")
    }

    private func stopSampling() {
        sampleTimer?.invalidate()
        sampleTimer = nil
        // Drop the CPU baseline so the next start computes a fresh delta
        // against a fresh wall-time anchor — otherwise the first sample
        // after re-activation would compare against a snapshot from a
        // long-past background period and report bogus 0% / huge %.
        lastCPUTimeNs = nil
        lastSampleAt = nil
        isSampling = false
        logger.debug("Sampling stopped")
    }

    // MARK: - Sampling

    private func sample() {
        if let rusage = currentRUsage() {
            memoryFootprintBytes = rusage.ri_phys_footprint

            let cpuTimeNs = rusage.ri_user_time + rusage.ri_system_time
            let now = Date()
            if let lastNs = lastCPUTimeNs, let lastAt = lastSampleAt {
                let dCPU = Double(cpuTimeNs &- lastNs)            // mach time → ns via timebase below
                let dWall = now.timeIntervalSince(lastAt) * 1_000_000_000.0
                if dWall > 0 {
                    cpuPercent = (dCPU * Self.machTickNs / dWall) * 100.0
                }
            }
            lastCPUTimeNs = cpuTimeNs
            lastSampleAt = now
        }

        if let device = metalDevice {
            gpuAllocatedBytes = UInt64(device.currentAllocatedSize)
        }
    }

    // MARK: - Darwin / mach helpers

    /// Cached mach timebase ratio. proc_pid_rusage's CPU times are in
    /// mach absolute time units; multiply by this to get nanoseconds.
    private static let machTickNs: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        guard info.denom != 0 else { return 1.0 }
        return Double(info.numer) / Double(info.denom)
    }()

    /// Fill `rusage_info_v4` for our own pid, or nil on failure.
    ///
    /// Bridging note (load-bearing): proc_pid_rusage's documented C
    /// signature is `int proc_pid_rusage(int pid, int flavor,
    /// rusage_info_t *buffer)` where `rusage_info_t` typedefs to
    /// `void *`. Read literally that's a `void **` — i.e. a pointer to
    /// a pointer to the destination — but XNU's actual implementation
    /// (`copyout(&ri, buffer, size)` in kern_resource.c) treats
    /// `buffer` as the destination address directly. The `*` in the
    /// signature is a historical type-erasure quirk; the kernel writes
    /// sizeof(flavor-struct) bytes starting at whatever pointer value
    /// the caller passed.
    ///
    /// Earlier versions of this code took the documented type
    /// literally and added an extra level of indirection
    /// (`var opaque = &info; proc_pid_rusage(pid, flavor, &opaque)`)
    /// which made the kernel write 240 bytes starting at the 8-byte
    /// stack slot for `opaque`, blowing through the stack canary by
    /// 232 bytes. The crash showed up as __stack_chk_fail at the
    /// proc_pid_rusage line, regardless of which flavor (v4, v6, …)
    /// we asked for.
    ///
    /// The right bridge is: take `&info` and rebind it to
    /// `rusage_info_t?` so the value passed to the syscall is the
    /// struct's address, not the address of a local pointer variable.
    ///
    /// Pinned to v4 (not v6 / not "current") because v4 has been
    /// stable since macOS 10.13 and carries every field we read
    /// (`ri_phys_footprint`, `ri_user_time`, `ri_system_time`); newer
    /// flavors only add fields we don't surface.
    private func currentRUsage() -> rusage_info_v4? {
        var info = rusage_info_v4()
        let pid = ProcessInfo.processInfo.processIdentifier
        let result: Int32 = withUnsafeMutablePointer(to: &info) { typedPtr in
            typedPtr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { reboundPtr in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, reboundPtr)
            }
        }
        guard result == 0 else {
            logger.error("proc_pid_rusage failed: \(result)")
            return nil
        }
        return info
    }
}
