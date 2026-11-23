import SwiftUI
import WatchKit

struct RecordingScreen: View {
    @ObservedObject var journal: WatchJournal
    let entry: Recording
    @Environment(\.scenePhase) private var phase
    @Environment(\.isLuminanceReduced) private var reduced
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("immediateRecordingLock") private var immediate = true
    @State private var guardState = RecordingGuard()
    @State private var holding = false
    @State private var progress = 0.0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if guardState.mode == .controls, phase == .active, !reduced {
                ScrollView {
                    VStack(spacing: 8) {
                        Text(entry.startedAt, style: .timer)
                            .font(.title2.monospacedDigit())
                            .accessibilityLabel("录音时长")
                            .accessibilityValue(Text(entry.startedAt, style: .timer))
                        if journal.collectionMode == .precise, let status = journal.collectionStatus {
                            Text(status).font(.caption2).foregroundStyle(.secondary)
                        }
                        Button(role: .destructive) { journal.finish() } label: {
                            Label("停止并保存", systemImage: "stop.fill")
                                .frame(maxWidth: .infinity, minHeight: 36)
                        }
                        .tint(.red)
                        .accessibilityIdentifier("recording.stop")
                        Button("锁定屏幕") { lock() }
                            .accessibilityIdentifier("recording.lock")
                    }
                    .padding(.horizontal, 8)
                }
                .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in
                    guardState.interact(voiceOver: voiceOver)
                })
            } else {
                lockedContent
            }
        }
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            guardState.begin(immediate: immediate)
            if phase != .active || reduced { lock() }
        }
        .onChange(of: phase) { if phase != .active { lock() } }
        .onChange(of: reduced) { if reduced { lock() } }
        .onChange(of: voiceOver) { lock() }
        #if DEBUG
        .task {
            guard ProcessInfo.processInfo.arguments.contains("-journal-recording-controls-preview") else { return }
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            unlock()
            writePreviewState()
        }
        .onChange(of: guardState) { writePreviewState() }
        #endif
        .task(id: guardState.deadline) {
            guard let deadline = guardState.deadline else { return }
            try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
            guard !Task.isCancelled, guardState.deadline == deadline else { return }
            // The sleep is monotonic: a wall-clock correction must not leave controls open.
            lock()
        }
    }

    private var lockedContent: some View {
        VStack(spacing: 10) {
            Label(guardState.mode == .confirming ? "已开始录音" : "录音中 · 已锁定",
                  systemImage: "mic.fill")
                .font(.caption2)
                .foregroundStyle(.gray)
            if !reduced {
                if voiceOver {
                    Button("解锁录音控制") { unlock() }
                        .accessibilityHint("解锁后可以停止并保存，录音不会立即结束")
                        .accessibilityIdentifier("recording.unlock")
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "lock.fill").font(.title3)
                        Text(holding ? "继续按住…" : "长按 1.5 秒解锁")
                            .font(.footnote)
                        ProgressView(value: progress).tint(.gray)
                            .opacity(holding ? 1 : 0)
                    }
                    .foregroundStyle(.gray)
                    .padding(16)
                    .frame(maxWidth: .infinity, minHeight: 100)
                    .contentShape(Rectangle())
                    .onLongPressGesture(minimumDuration: RecordingGuard.holdDuration,
                                        maximumDistance: 18, perform: unlock) { pressed in
                        holding = pressed
                        if pressed {
                            withAnimation(reduceMotion ? nil : .linear(duration: RecordingGuard.holdDuration)) {
                                progress = 1
                            }
                        } else { progress = 0 }
                    }
                    .accessibilityIdentifier("recording.hold")
                }
            }
        }
        .padding(.horizontal, 12)
        .allowsHitTesting(phase == .active && !reduced)
        .accessibilityIdentifier("recording.locked")
    }

    private func unlock() {
        guardState.unlock(active: phase == .active, reduced: reduced, voiceOver: voiceOver)
        holding = false
        progress = 0
        if guardState.mode == .controls { WKInterfaceDevice.current().play(.click) }
    }

    private func lock() {
        guardState.lock()
        holding = false
        progress = 0
    }

    #if DEBUG
    private func writePreviewState() {
        guard ProcessInfo.processInfo.arguments.contains("-journal-recording-controls-preview") else { return }
        // Programmatic render probe only; this does not simulate a touch or VoiceOver.
        let state: [String: Any] = ["mode": String(describing: guardState.mode),
                                    "active": phase == .active, "reduced": reduced]
        try? JSONSerialization.data(withJSONObject: state)
            .write(to: journal.store.localStateURL("recording-ui-state.json"), options: .atomic)
    }
    #endif
}
