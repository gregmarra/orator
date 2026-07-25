import AppKit
import SwiftUI
import Observation

/// The AppKit application delegate — the composition root. AppKit lifecycle is used deliberately
/// (§11.1): global hotkeys, non-activating panels, and Accessibility control are AppKit-native and
/// fight the SwiftUI scene model.
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    // Collaborators (single instances for the app lifetime).
    private let permissions = PermissionsManager()
    private let feedback = SoundFeedback()
    private let recovery = RecoveryBuffer()
    private let inserter = TextInserter()
    private let audio = AudioCapture()
    // Seed the biasing preference so the very first dictation's PREPARED session is already the
    // vocabulary-capable kind, instead of having to build one inline on the hotkey path.
    private lazy var engine = SpeechEngine(locale: Settings.shared.locale,
                                           biasing: !Settings.shared.vocabulary.isEmpty)
    private lazy var coordinator = SessionCoordinator(
        audio: audio, engine: engine, inserter: inserter,
        recovery: recovery, permissions: permissions, feedback: feedback)

    private lazy var statusItem = StatusItemController(coordinator: coordinator)
    private let indicator = IndicatorController()
    private lazy var hotkey = HotkeyManager(onFire: { [weak self] in
        Task { @MainActor in self?.coordinator.toggle() }
    })

    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private let onboarding = OnboardingModel()
    private lazy var language = LanguageModel(selectedID: Settings.shared.localeIdentifier)

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // LSUIElement / no Dock icon (ORA-PLAT-004)

        // A programmatic main menu (HIG SET-1): without one, standard key equivalents (⌘C/V/X/A,
        // ⌘W…) are dead in the Settings/Onboarding windows. Built with plain NSMenu — the SwiftUI
        // `Settings`/`MenuBarExtra` scenes hit a fatal executor crash on this toolchain (§11.1).
        buildMainMenu()

        // Menu-bar item + observers FIRST so the icon appears before slow audio/speech setup.
        wireStatusItem()
        wireOnboarding()
        wireLanguage()
        startObserving()

        // Re-check permissions on focus so a System Settings grant takes effect without a restart,
        // and stale grants surface (ORA-PERM-002).
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in await self?.refreshAndWarm() } }

        hotkey.register(Settings.shared.hotkey)
        // Full bring-up: readiness → onboarding sync → warm engine. Setup is guided through the
        // crash-free menu-bar menu, not an auto-shown SwiftUI window; the icon reflects not-ready.
        Task { await refreshAndWarm() }
    }

    private func warmEngineIfPossible() async {
        guard !engine.isWarm, await engine.modelStatus() == .installed else { return }
        do { try await engine.warmUp() }
        catch { Log.speech.error("warmUp failed: \(error.localizedDescription)") }
        await coordinator.refreshReadiness()
        await ensureVocabularyBiasingUsable()
    }

    /// A custom vocabulary only biases recognition on `DictationTranscriber`, whose asset is NOT
    /// implied by the one an existing install already has. Fetch it in the background once, after warm
    /// -up, so the advertised feature actually works instead of silently degrading — and tell the user
    /// if it can't be had, since the alternative is a Settings pane promising something inert.
    private func ensureVocabularyBiasingUsable() async {
        guard !Settings.shared.vocabulary.isEmpty else { return }
        guard await !engine.biasingAssetInstalled() else { return }
        if await engine.ensureBiasingAsset() {
            Log.speech.notice("Custom vocabulary is now active")
        } else {
            coordinator.reportVocabularyUnavailable()
        }
    }

    private func refreshAndWarm() async {
        await coordinator.refreshReadiness()
        await syncOnboarding()
        await warmEngineIfPossible()
        render()
    }

    // MARK: Observation → UI (status icon + indicator)

    private func startObserving() {
        render()
        withObservationTracking {
            _ = coordinator.state
            _ = coordinator.readiness
            _ = coordinator.elapsed
            _ = coordinator.audioLevel
            _ = coordinator.volatilePreview
            _ = coordinator.notice
        } onChange: { [weak self] in
            // startObserving() re-renders as its first line, then re-subscribes.
            Task { @MainActor in self?.startObserving() }
        }
    }

    private func render() {
        statusItem.updateIcon()
        // Driven by `indicatorVisible`, not by state alone: a terminal notice (text saved to the menu,
        // nothing heard, mic lost) keeps the panel up briefly after the session returns to idle, so a
        // failed dictation doesn't collapse exactly like a successful one.
        if coordinator.indicatorVisible {
            // First call shows the panel; while visible, show() is just a content update. The
            // controller decides notch vs pill.
            indicator.show(content: coordinator.indicatorContent())
        } else {
            indicator.hide()
        }
    }

    // MARK: Main menu (HIG SET-1)

    /// Minimal main menu so the standard responder-chain key equivalents work in our windows.
    /// All Edit/Window items use nil-targeted standard selectors, so they resolve against the
    /// focused responder (e.g. the field editor of a SwiftUI TextField) exactly like a stock app.
    private func buildMainMenu() {
        let main = NSMenu()
        func addTopLevelMenu(_ submenu: NSMenu) {   // wrap a submenu in an (untitled) item and append
            let item = NSMenuItem()
            item.submenu = submenu
            main.addItem(item)
        }

        // App menu (first item; its title is ignored — the system shows the app name).
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Orator",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings…",
                                      action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Orator",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        addTopLevelMenu(appMenu)

        // Edit menu — standard nil-targeted selectors reach the focused NSTextView.
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All",
                         action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        addTopLevelMenu(editMenu)

        // Window menu — ⌘W/⌘M for the Settings and Onboarding windows.
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close",
                           action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize",
                           action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        addTopLevelMenu(windowMenu)

        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }

    // MARK: Wiring

    private func wireStatusItem() {
        statusItem.onOpenSettings = { [weak self] in self?.showSettings() }
        statusItem.onQuit = { NSApp.terminate(nil) }
        statusItem.onFixReadiness = { [weak self] in self?.handleFixReadiness() }
        statusItem.onCancelDictation = { [weak self] in self?.coordinator.cancel() }
        statusItem.onGrantMicrophone = { [weak self] in
            Task { _ = await self?.permissions.requestMicrophone(); await self?.refreshAndWarm() }
        }
        statusItem.onGrantAccessibility = { [weak self] in
            self?.permissions.promptAccessibility()
            self?.permissions.openSettings(for: .accessibility)
        }
        // Re-check permissions each time the menu opens — an accessory app rarely fires
        // didBecomeActive, so this is the reliable re-check hook (ORA-PERM-002).
        statusItem.onMenuWillOpen = { [weak self] in Task { await self?.refreshAndWarm() } }
    }

    private func wireLanguage() {
        // Read the supported/installed locales straight from the transcriber — the picker is never
        // hard-coded (ORA-ASR-006).
        language.reload = { [weak self] in
            guard let self else { return }
            let supported = await self.engine.supportedLocaleIDs()
            let installed = await self.engine.installedLocaleIDs()
            self.language.installedIDs = Set(installed)
            self.language.options = supported.sorted {
                self.language.displayName($0).localizedCaseInsensitiveCompare(self.language.displayName($1)) == .orderedAscending
            }
        }
        // Switch to a language, triggering the OS model install first if it isn't present. Only while
        // idle — a mid-dictation switch would tear down the live analyzer. `Settings`/`appliedID` are
        // committed only on SUCCESS; on cancel-via-not-idle or failure we revert to the prior locale
        // (and restore a working engine) so a failed download never leaves a broken selection.
        language.select = { [weak self] id in
            guard let self else { return }
            guard self.coordinator.state == .idle else {
                self.language.selectedID = self.language.appliedID   // can't switch mid-dictation
                return
            }
            guard id != self.language.appliedID else { return }
            self.language.errorText = nil
            if !self.language.isInstalled(id) { self.language.downloadingID = id; self.language.progress = 0 }
            do {
                try await self.engine.switchLocale(Locale(identifier: id)) { fraction in
                    Task { @MainActor in self.language.progress = fraction }
                }
                self.language.installedIDs.insert(id)
                self.language.appliedID = id
                Settings.shared.localeIdentifier = id
            } catch {
                Log.speech.notice("Language switch failed: \(error.localizedDescription)")
                self.language.errorText = "Couldn't install \(self.language.displayName(id)) — \(error.localizedDescription)"
                self.language.selectedID = self.language.appliedID
                try? await self.engine.rewarm(locale: Locale(identifier: self.language.appliedID))
            }
            self.language.downloadingID = nil
            await self.coordinator.refreshReadiness()
            self.render()
        }
    }

    private func handleFixReadiness() {
        switch coordinator.readiness {
        case .needsPermission(let missing):
            // Also open the guided setup window, not just the System Settings deep links: it is the
            // screen that explains what each grant is for and carries the per-permission reset.
            for kind in missing { permissions.openSettings(for: kind) }
            showOnboarding()
        case .needsModel:
            showOnboarding()
        default:
            break
        }
    }

    private func wireOnboarding() {
        onboarding.requestMic = { [weak self] in
            _ = await self?.permissions.requestMicrophone()
            await self?.syncOnboarding()
        }
        onboarding.promptAccessibility = { [weak self] in
            self?.permissions.promptAccessibility()
        }
        onboarding.openMicSettings = { [weak self] in self?.permissions.openSettings(for: .microphone) }
        onboarding.openAccessibilitySettings = { [weak self] in self?.permissions.openSettings(for: .accessibility) }
        onboarding.resetMic = { [weak self] in self?.resetPermission(.microphone) }
        onboarding.resetAccessibility = { [weak self] in self?.resetPermission(.accessibility) }
        onboarding.downloadModel = { [weak self] in await self?.runModelDownload() }
        onboarding.finish = { [weak self] in
            self?.onboardingWindow?.close()
            Task { await self?.refreshAndWarm() }
        }
    }

    /// Fully revoke a permission (escape a stuck grant), then re-check readiness (which re-syncs
    /// onboarding too).
    private func resetPermission(_ kind: PermissionKind) {
        permissions.reset(kind)
        Task { await refreshAndWarm() }
    }

    private func runModelDownload() async {
        onboarding.modelStatus = .downloading(fractionCompleted: 0)
        do {
            try await engine.installModel { fraction in
                Task { @MainActor in self.onboarding.modelStatus = .downloading(fractionCompleted: fraction) }
            }
            onboarding.modelStatus = .installed
            await warmEngineIfPossible()
        } catch {
            onboarding.modelStatus = .failed(error.localizedDescription)
        }
        await coordinator.refreshReadiness()
    }

    private func syncOnboarding() async {
        onboarding.micGranted = permissions.microphoneGranted
        onboarding.accessibilityGranted = permissions.accessibilityGranted
        onboarding.modelStatus = await engine.modelStatus()
    }

    // MARK: Windows

    // Create SwiftUI windows on a fresh run-loop turn, NOT synchronously inside a status-menu action.
    // Building an NSHostingController's SwiftUI content while NSMenu tracking is unwinding trips a
    // Swift-concurrency executor assertion inside SwiftUI on this toolchain; deferring dodges it.
    @objc private func showSettings() {
        DispatchQueue.main.async { [weak self] in self?.presentSettings() }
    }
    private func showOnboarding() { DispatchQueue.main.async { [weak self] in self?.presentOnboarding() } }

    private func presentSettings() {
        promoteToRegular()
        if let w = settingsWindow { bringUpFront(w); return }
        let view = SettingsView(
            language: language,
            onHotkeyChange: { [weak self] chord in self?.hotkey.register(chord) },
            onHotkeyRecording: { [weak self] active in
                // Suspend the global hotkey while recording so pressing the current combo reaches the
                // recorder instead of firing Orator; restore it (with whatever chord is now set) after.
                if active { self?.hotkey.unregister() }
                else { self?.hotkey.register(Settings.shared.hotkey) }
            },
            onReset: { [weak self] in self?.showOnboarding() })
        let w = makeWindow(title: "Orator Settings", autosave: "OratorSettings", content: view)
        settingsWindow = w
        bringUpFront(w)
    }

    private func presentOnboarding() {
        promoteToRegular()
        Task { await syncOnboarding() }
        if let w = onboardingWindow { bringUpFront(w); return }
        let w = makeWindow(title: "Welcome to Orator", autosave: "OratorOnboarding",
                           content: OnboardingView(model: onboarding))
        onboardingWindow = w
        bringUpFront(w)
    }

    /// A menu-bar (accessory) app must promote to a regular app to reliably show a real window
    /// (a Dock icon appears while a window is open); we revert to accessory when they all close.
    private func promoteToRegular() {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func bringUpFront(_ w: NSWindow) {
        w.delegate = self
        // Do NOT re-center: a Settings window should reopen where the user last left it (the frame
        // is persisted via its autosave name in makeWindow). Centering only happens on first creation.
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()
    }

    /// When our last window closes, drop back to a menu-bar agent (no Dock icon).
    public func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let anyVisible = (self.settingsWindow?.isVisible ?? false) || (self.onboardingWindow?.isVisible ?? false)
            if !anyVisible { NSApp.setActivationPolicy(.accessory) }
        }
    }

    private func makeWindow<Content: View>(title: String, autosave: String, content: Content) -> NSWindow {
        let hosting = NSHostingController(rootView: content)
        hosting.sizingOptions = [.preferredContentSize]   // let SwiftUI drive the window size
        let w = NSWindow(contentViewController: hosting)
        w.title = title
        // Fixed-size Settings window: titled + closable only (no resize/minimize), per the macOS
        // single-pane Settings idiom (SET-1).
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        // Force layout so the SwiftUI fitting size is known, then size the window to it (otherwise a
        // freshly-created hosting controller reports a ~1×32 fitting size).
        hosting.view.layoutSubtreeIfNeeded()
        let fit = hosting.view.fittingSize
        if fit.width > 50, fit.height > 50 { w.setContentSize(fit) }
        // Persist + restore the window position across opens; center only on the very first launch.
        w.setFrameAutosaveName(autosave)
        if !w.setFrameUsingName(autosave) { w.center() }
        return w
    }
}
