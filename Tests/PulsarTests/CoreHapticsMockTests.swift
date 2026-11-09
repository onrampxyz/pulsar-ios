import Testing
import Foundation
import CoreHaptics
import UIKit
@testable import Pulsar

/// Verifies the engine wrapper *drives* CoreHaptics correctly, using the swizzled `CoreHapticsMock`
/// so the real (simulator-unavailable) engine is stood in for. Serialized + isolated because the
/// swizzle is process-global — run these via a separate `-only-testing` invocation.
@MainActor
@Suite(.serialized)
struct CoreHapticsMockTests {

    private func makePattern() -> CHHapticPattern? {
        let event = CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: 1)],
            relativeTime: 0
        )
        return try? CHHapticPattern(events: [event], parameters: [])
    }

    /// Builds a wrapper, runs its one-time lifecycle bootstrap, then forces the app-active state so
    /// `canPlayHaptics()` is deterministic regardless of the test host's UIApplication state.
    private func activeEngine(resetAfterWarmup: Bool = true, waitForStart: Bool = true) async -> HapticEngineWrapper {
        let engine = HapticEngineWrapper()
        _ = engine.createPlayer(pattern: nil)          // trigger bootstrap/seed
        engine.updatePlaybackAvailability(for: .active) // force active
        if waitForStart {
            _ = engine.createPlayer(pattern: nil)      // start the engine (asynchronously)
            await waitUntil { engine.isEngineRunning }
        }
        if resetAfterWarmup { HapticMockRecorder.shared.reset() }
        return engine
    }

    /// The engine starts off the main thread and reports back on main, so yield the main actor.
    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @Test func mockedEngineConstructsStartsAndCreatesPlayers() async {
        CoreHapticsMock.install()
        defer { CoreHapticsMock.uninstall() }

        let engine = await activeEngine(resetAfterWarmup: false)
        let id = engine.createPlayer(pattern: makePattern())

        #expect(id != nil)
        #expect(HapticMockRecorder.shared.enginesCreated >= 1)
        #expect(HapticMockRecorder.shared.startCalls >= 1)
    }

    @Test func engineStartsOffTheMainThreadAndPlayersAreBuiltOnFirstPlay() async {
        CoreHapticsMock.install()
        defer { CoreHapticsMock.uninstall() }

        let engine = await activeEngine(resetAfterWarmup: false, waitForStart: false)
        let pattern = makePattern()
        let created = engine.createPlayer(pattern: pattern)
        #expect(created != nil)
        #expect(!engine.isEngineRunning)
        #expect(HapticMockRecorder.shared.playersCreated == 0)
        guard let id = created else { return }

        await waitUntil { engine.isEngineRunning }
        #expect(engine.isEngineRunning)
        #expect(HapticMockRecorder.shared.engineCallsOnMainThread == 0)

        engine.playPlayer(id: id, pattern: pattern)
        #expect(HapticMockRecorder.shared.playersCreated == 1)
        #expect(HapticMockRecorder.shared.playerStarts == 1)
    }

    @Test func stoppingWhileTheEngineStartsDiscardsTheStart() async {
        CoreHapticsMock.install()
        defer { CoreHapticsMock.uninstall() }

        let engine = await activeEngine(waitForStart: false)
        _ = engine.createPlayer(pattern: makePattern())
        engine.stopHaptics()

        await waitUntil(timeout: 0.3) { engine.isEngineRunning }
        #expect(!engine.isEngineRunning)
    }

    /// A synchronous TurboModule method (`PatternComposer_parsePattern`) runs on the JavaScript
    /// thread, not on the module's main `methodQueue`, so the wrapper has to hop to main itself.
    @Test func createPlayerFromABackgroundThreadBuildsThePlayerOnMain() async {
        CoreHapticsMock.install()
        defer { CoreHapticsMock.uninstall() }

        let engine = await activeEngine()
        let id: Int? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: engine.createPlayer(pattern: nil))
            }
        }

        #expect(id != nil)
        #expect(HapticMockRecorder.shared.playersCreated == 1)
        #expect(HapticMockRecorder.shared.playerBuildsOffMainThread == 0)
    }

    @Test func createPlayerReturnsDistinctIdsAndBuildsAPlayerEachTime() async {
        CoreHapticsMock.install()
        defer { CoreHapticsMock.uninstall() }

        let engine = await activeEngine()
        let a = engine.createPlayer(pattern: makePattern())
        let b = engine.createPlayer(pattern: makePattern())

        #expect(a != nil && b != nil)
        #expect(a != b)
        #expect(HapticMockRecorder.shared.playersCreated == 2)
    }

    @Test func registryEvictsTheOldestPlayerBeyondTheLimit() async {
        CoreHapticsMock.install()
        defer { CoreHapticsMock.uninstall() }

        let engine = await activeEngine()
        // playerLimit is 20; the 21st creation must evict (and stop) the oldest.
        for _ in 0..<21 { _ = engine.createPlayer(pattern: makePattern()) }

        #expect(HapticMockRecorder.shared.playersCreated == 21)
        #expect(HapticMockRecorder.shared.playerStops >= 1)
    }

    @Test func stopHapticsStopsEveryRegisteredPlayer() async {
        CoreHapticsMock.install()
        defer { CoreHapticsMock.uninstall() }

        let engine = await activeEngine()
        for _ in 0..<3 { _ = engine.createPlayer(pattern: makePattern()) }
        engine.stopHaptics()

        #expect(HapticMockRecorder.shared.playerStops >= 3)
    }

    @Test func realtimeComposerActivatesAndSendsClampedParameters() async {
        CoreHapticsMock.install()
        defer { CoreHapticsMock.uninstall() }

        let engine = await activeEngine()
        let composer = RealtimeComposer(engine: engine)
        composer.set(amplitude: 2.0, frequency: -1.0) // out of range

        #expect(composer.isActive)
        #expect(HapticMockRecorder.shared.advancedPlayersCreated >= 1)
        #expect(HapticMockRecorder.shared.playerStarts >= 1)

        let last = HapticMockRecorder.shared.sentParameters.last
        #expect(last?.intensity == 1.0)   // clamped up-bound
        #expect(last?.sharpness == 0.0)   // clamped low-bound
    }

    @Test func stopDeactivatesTheRealtimeComposer() async {
        CoreHapticsMock.install()
        defer { CoreHapticsMock.uninstall() }

        let engine = await activeEngine()
        let composer = RealtimeComposer(engine: engine)
        composer.set(amplitude: 0.5, frequency: 0.5)
        #expect(composer.isActive)

        composer.stop()
        #expect(!composer.isActive)
        #expect(HapticMockRecorder.shared.playerStops >= 1)
    }

    /// Sound in this version is synthesized by `AudioSimulator` on its own AVAudioEngine and never
    /// touches the haptic engine. Parsing a pattern with sound while the engine is still starting
    /// (the mock engine takes half a second to initialize here) has to return at once, the main
    /// thread has to stay free for the whole start, and the haptic players are built on first play.
    @Test func parsingAPatternWithSoundWhileTheEngineStartsNeverBlocksMain() async {
        CoreHapticsMock.install()
        defer { CoreHapticsMock.uninstall() }
        HapticMockRecorder.shared.engineInitDelay = 0.5

        let engine = HapticEngineWrapper()
        _ = engine.createPlayer(pattern: nil)           // bootstrap; may already start the slow engine
        engine.updatePlaybackAvailability(for: .active)
        let simulator = AudioSimulator()
        simulator.enableSound(true)
        let composer = Unchecked(PatternComposer(engine: engine, audioSimulator: simulator))
        let data = Unchecked(PatternData(
            line: [[[0, 0.0], [100, 1.0], [200, 0.0]], [[0, 0.5], [200, 0.5]]],
            bar: [[0, 1.0, 0.3]]
        ))

        // The way a synchronous TurboModule call arrives: from a thread that is not main.
        let parseDuration: TimeInterval = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let started = Date()
                composer.value.parsePattern(hapticsData: data.value)
                continuation.resume(returning: Date().timeIntervalSince(started))
            }
        }
        #expect(parseDuration < 0.25)
        #expect(!engine.isEngineRunning)
        #expect(HapticMockRecorder.shared.playersCreated == 0)

        let probe = MainThreadProbe()
        probe.start()
        await waitUntil { engine.isEngineRunning }
        probe.stop()
        #expect(engine.isEngineRunning)
        #expect(probe.longestRoundTrip < 0.25)
        #expect(HapticMockRecorder.shared.engineCallsOnMainThread == 0)

        composer.value.play()
        #expect(HapticMockRecorder.shared.playersCreated == 2)
        #expect(HapticMockRecorder.shared.playerStarts == 2)
    }
}

/// Measures the longest `DispatchQueue.main.sync` round trip from a background thread: a main
/// thread that waits on the engine shows up as a round trip as long as the engine start.
private final class MainThreadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var running = false
    private var longest: TimeInterval = 0

    var longestRoundTrip: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return longest
    }

    func start() {
        lock.lock(); running = true; lock.unlock()
        Thread.detachNewThread { [self] in
            while isRunning {
                let started = Date()
                DispatchQueue.main.sync {}
                record(Date().timeIntervalSince(started))
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
    }

    func stop() {
        lock.lock(); running = false; lock.unlock()
    }

    private var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    private func record(_ duration: TimeInterval) {
        lock.lock(); longest = max(longest, duration); lock.unlock()
    }
}

/// Lets a value that is not `Sendable` cross to a background queue inside a test.
private struct Unchecked<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
