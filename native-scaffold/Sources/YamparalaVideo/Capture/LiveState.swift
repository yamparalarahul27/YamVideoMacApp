import Foundation

/// The handful of control values that realtime capture callbacks need to read
/// while the UI owns them on the main actor. Kept in its own non-isolated type
/// so neither side has to reach across an actor boundary on the audio thread.
final class LiveState: @unchecked Sendable {
    static let shared = LiveState()

    private let lock = NSLock()
    private var micGain: Float = LiveState.linearGain(forDB: -6, muted: false)
    private var gameGain: Float = LiveState.linearGain(forDB: -14, muted: false)
    private var mirrored = true
    private var hidden = false
    private var placement = CameraPlacement()
    private var layout = RecordingLayout.sideBySide

    static func linearGain(forDB db: Float, muted: Bool) -> Float {
        muted ? 0 : pow(10, db / 20)
    }

    func setGains(micDB: Float, micMuted: Bool, gameDB: Float, gameMuted: Bool) {
        let mic = Self.linearGain(forDB: micDB, muted: micMuted)
        let game = Self.linearGain(forDB: gameDB, muted: gameMuted)
        lock.withLock { micGain = mic; gameGain = game }
    }

    func setCamera(mirrored: Bool, hidden: Bool) {
        lock.withLock { self.mirrored = mirrored; self.hidden = hidden }
    }

    func setPlacement(_ value: CameraPlacement) { lock.withLock { placement = value } }
    func setLayout(_ value: RecordingLayout) { lock.withLock { layout = value } }

    var placementValue: CameraPlacement { lock.withLock { placement } }
    var layoutValue: RecordingLayout { lock.withLock { layout } }

    var micGainValue: Float { lock.withLock { micGain } }
    var gameGainValue: Float { lock.withLock { gameGain } }
    var isMirrored: Bool { lock.withLock { mirrored } }
    var isHidden: Bool { lock.withLock { hidden } }
}
