import SwiftUI

/// Drives first-run onboarding: permissions (§6.4) and model acquisition (§8.4), with clear,
/// offline-friendly states (ORA-LIF-002). Download failure is a first-class, retryable state, never
/// a fatal error (E4). Also reached later via "Reset setup" (§4 scenario 6).
@MainActor
@Observable
public final class OnboardingModel {
    public var micGranted = false
    public var accessibilityGranted = false
    public var modelStatus: ModelStatus = .missing

    public var requestMic: (() async -> Void)?
    public var promptAccessibility: (() -> Void)?
    public var openMicSettings: (() -> Void)?
    public var openAccessibilitySettings: (() -> Void)?
    /// Fully revoke a permission (tccutil reset) to escape a stuck grant, then re-grant fresh.
    public var resetMic: (() -> Void)?
    public var resetAccessibility: (() -> Void)?
    public var downloadModel: (() async -> Void)?
    public var finish: (() -> Void)?

    public init() {}

    public var isComplete: Bool {
        micGranted && accessibilityGranted && modelStatus == .installed
    }
}

public struct OnboardingView: View {
    @Bindable var model: OnboardingModel
    public init(model: OnboardingModel) { self._model = Bindable(model) }

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Welcome to Orator").font(.largeTitle.bold())
                Text("Press your hotkey, speak, press again — your words land in the focused field. Entirely on-device.")
                    .foregroundStyle(.secondary)
            }

            step(done: model.micGranted, title: PermissionKind.microphone.title,
                 detail: PermissionKind.microphone.purpose, reset: model.resetMic) {
                Button("Grant Microphone") { Task { await model.requestMic?() } }
                Button("Open System Settings") { model.openMicSettings?() }.buttonStyle(.bordered)
            }

            step(done: model.accessibilityGranted, title: PermissionKind.accessibility.title,
                 detail: PermissionKind.accessibility.purpose, reset: model.resetAccessibility) {
                Button("Grant Accessibility") { model.promptAccessibility?() }
                Button("Open System Settings") { model.openAccessibilitySettings?() }.buttonStyle(.bordered)
            }

            step(done: model.modelStatus == .installed, title: "Speech model",
                 detail: model.modelStatus.summary) {
                modelControl
            }

            Spacer()
            HStack {
                Spacer()
                Button("Done") { model.finish?() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.isComplete)
            }
        }
        .padding(28)
        .frame(width: 520, height: 480)
    }

    @ViewBuilder private var modelControl: some View {
        switch model.modelStatus {
        case .installed:
            EmptyView()
        case .downloading(let f):
            ProgressView(value: f) { Text("Downloading… \(Int(f * 100))%") }
        case .missing:
            Button("Download model") { Task { await model.downloadModel?() } }
        case .failed:
            // The reason is already stated in the step's detail line (`ModelStatus.summary`).
            Button("Retry") { Task { await model.downloadModel?() } }
        case .unsupported:
            Text("This language isn't supported on this Mac.").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func step<Controls: View>(done: Bool, title: String, detail: String,
                                      reset: (() -> Void)? = nil,
                                      @ViewBuilder controls: () -> Controls) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? .green : .secondary)
                .font(.title2)
                // Celebrate completion: the circle swaps to the checkmark with a symbol replace
                // transition and a bounce (ONB-1). Decorative — VoiceOver reads the row label.
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: done)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary).font(.callout)
                if !done { HStack(spacing: 12) { controls() } }
                // Always-available escape hatch for a STUCK permission (e.g. Accessibility that reads
                // granted in System Settings but is effectively off): fully revoke, then re-grant.
                if let reset {
                    Button("Reset permission", role: .destructive, action: reset)
                        .buttonStyle(.link)
                        .controlSize(.small)
                        .help("Fully revokes this permission (tccutil reset) so you can grant it again from scratch — use if it's stuck. A relaunch may be needed.")
                }
            }
            Spacer()
        }
        .accessibilityLabel("\(title), \(done ? "complete" : "not complete")")   // ONB-2
    }
}
