import Foundation

@main
enum RecordingExperienceRegression {
    static var checks = 0
    static func check(_ value: @autoclosure () throws -> Bool, _ name: String) throws {
        guard try value() else { fatalError("FAIL: \(name)") }
        checks += 1
    }

    static func main() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        var state = RecordingGuard()
        state.begin(immediate: true, now: now)
        try check(state.mode == .locked && state.deadline == nil, "immediate lock has no recurring timer")
        state.expire(now: now.addingTimeInterval(3600))
        try check(state.mode == .locked, "elapsed time alone cannot unlock")
        state.begin(immediate: false, now: now)
        state.expire(now: now.addingTimeInterval(0.99))
        try check(state.mode == .confirming, "brief confirmation lasts one second")
        state.expire(now: now.addingTimeInterval(1))
        try check(state.mode == .locked && state.deadline == nil, "confirmation locks at deadline")
        state.unlock(active: false, reduced: false, voiceOver: false, now: now)
        try check(state.mode == .locked, "inactive gestures cannot unlock")
        state.unlock(active: true, reduced: true, voiceOver: false, now: now)
        try check(state.mode == .locked, "always on gestures cannot unlock")
        state.unlock(active: true, reduced: false, voiceOver: false, now: now)
        try check(state.mode == .controls, "explicit unlock exposes controls")
        state.expire(now: now.addingTimeInterval(4.99))
        try check(state.mode == .controls, "controls remain available before timeout")
        state.expire(now: now.addingTimeInterval(5))
        try check(state.mode == .locked && state.deadline == nil, "idle controls relock at five seconds")
        state.interact(voiceOver: false, now: now)
        try check(state.mode == .locked && state.deadline == nil, "ordinary touch cannot unlock")
        state.unlock(active: true, reduced: false, voiceOver: false, now: now)
        state.interact(voiceOver: false, now: now.addingTimeInterval(4))
        state.expire(now: now.addingTimeInterval(5))
        try check(state.mode == .controls, "control interaction extends idle deadline")
        state.expire(now: now.addingTimeInterval(9))
        try check(state.mode == .locked, "controls relock five seconds after interaction")
        state.unlock(active: true, reduced: false, voiceOver: true, now: now)
        try check(state.mode == .controls && state.deadline == nil, "VoiceOver has time to read and act")
        state.lock()
        try check(state.mode == .locked, "wrist down locks VoiceOver controls too")
        state.unlock(active: true, reduced: false, voiceOver: false, now: now)
        state.begin(immediate: true, now: now.addingTimeInterval(1))
        state.expire(now: now.addingTimeInterval(5))
        try check(state.mode == .locked && state.deadline == nil, "new session discards old control deadline")
        state.unlock(active: true, reduced: false, voiceOver: false, now: now.addingTimeInterval(10))
        state.expire(now: now.addingTimeInterval(5))
        try check(state.mode == .controls, "stale timeout cannot close newly opened controls")
        try check(RecordingPreflight.warning(battery: -1, charging: false, free: nil) == nil, "unknown battery and space are not false warnings")
        try check(RecordingPreflight.warning(battery: 0.19, charging: false, free: nil) != nil, "low battery warns")
        try check(RecordingPreflight.warning(battery: 0.19, charging: true, free: nil) == nil, "charging suppresses low battery warning")
        try check(RecordingPreflight.warning(battery: 0.8, charging: false, free: 32 * 1024 * 1024) != nil, "low space warns")
        try check(RecordingPreflight.warning(battery: 0.8, charging: false, free: 128 * 1024 * 1024) == nil, "adequate space starts without prompt")
        for outcome in [RecordingReceipt.Outcome.saved, .interrupted, .failed] {
            let receipt = RecordingReceipt(id: UUID(), outcome: outcome, detail: "持久提示")
            let decoded = try JSONDecoder().decode(RecordingReceipt.self, from: JSONEncoder().encode(receipt))
            try check(decoded == receipt, "receipt round trip: \(outcome)")
        }
        print("PASS: \(checks) recording experience checks")
    }
}
