import Foundation
import IslandCore
import Observation

/// Volume state for the UI and the island HUD.
@MainActor
@Observable
final class VolumeController {
    private(set) var level: Double = 0
    private(set) var isMuted = false
    private(set) var deviceName: String?
    private(set) var isHeadphones = false
    private(set) var canSetVolume = false
    private(set) var isAvailable = false

    @ObservationIgnored var onEvent: ((IslandEvent) -> Void)?
    @ObservationIgnored private let audio = SystemAudioService()
    @ObservationIgnored private var settings: IslandSettings.Volume
    @ObservationIgnored private var levelBeforeMute: Double?

    init(settings: IslandSettings.Volume) {
        self.settings = settings
    }

    func start() {
        audio.onVolumeChange = { [weak self] level, muted in
            self?.volumeChanged(level: Double(level), muted: muted)
        }
        audio.onOutputChange = { [weak self] output in
            self?.outputChanged(output)
        }
        audio.start()
        syncFromDevice()
    }

    func stop() {
        audio.stop()
    }

    func refresh() {
        audio.refresh()
        syncFromDevice()
    }

    func apply(settings new: IslandSettings.Volume) {
        settings = new
    }

    // MARK: - Control

    func setLevel(_ value: Double) {
        guard canSetVolume else { return }
        audio.setVolume(Float(value))
    }

    /// One volume key press (16 steps, 64 with ⌥⇧). Shows the HUD even at the
    /// limits, like the system does.
    func step(up: Bool, fine: Bool) {
        guard canSetVolume else { return }
        if isMuted && up {
            audio.setMuted(false)
        }
        let target = LevelStepper.step(isMuted ? 0 : level, up: up, fine: fine)
        audio.setVolume(Float(target))
        if target == level {
            publish()
        }
    }

    func toggleMute() {
        if audio.output?.hasMute == true {
            audio.setMuted(!isMuted)
            return
        }
        // Devices without a mute control: mute is "volume 0".
        if level > 0 {
            levelBeforeMute = level
            audio.setVolume(0)
        } else {
            audio.setVolume(Float(levelBeforeMute ?? 0.25))
        }
    }

    // MARK: - Updates

    private func syncFromDevice() {
        let output = audio.output
        isAvailable = output != nil
        deviceName = output?.name
        isHeadphones = output?.isHeadphones ?? false
        canSetVolume = output?.canSetVolume ?? false
        level = Double(audio.volume ?? 0)
        isMuted = audio.isMuted
    }

    private func volumeChanged(level: Double, muted: Bool) {
        self.level = level
        self.isMuted = muted
        publish()
    }

    private func publish() {
        onEvent?(.volumeChanged(level: level, muted: isMuted, device: isHeadphones ? deviceName : nil))
    }

    private func outputChanged(_ output: SystemAudioService.Output?) {
        syncFromDevice()
        guard let output else { return }
        onEvent?(.outputDeviceChanged(name: output.name, isHeadphones: output.isHeadphones))
    }
}
