import AudioToolbox
import CoreAudio
import Foundation

/// Default output device volume through the public CoreAudio HAL API.
///
/// Event driven: property listeners on the system object (default device
/// changes) and on the device (volume, mute, data source). No polling.
@MainActor
final class SystemAudioService {
    struct Output: Equatable {
        let id: AudioObjectID
        let name: String
        let isHeadphones: Bool
        let canSetVolume: Bool
        let hasMute: Bool
    }

    /// Called with (volume 0...1, muted) when the level or mute state changes.
    var onVolumeChange: ((Float, Bool) -> Void)?
    /// Called when the default output device changes.
    var onOutputChange: ((Output?) -> Void)?

    private(set) var output: Output?
    private var deviceListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var systemListener: AudioObjectPropertyListenerBlock?
    private var isStarted = false

    private static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    private static let defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private static func volumeAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func muteAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func dataSourceAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSource,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    // MARK: - Lifecycle

    func start() {
        guard !isStarted else { return }
        isStarted = true
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.bindDefaultDevice(notify: true)
            }
        }
        systemListener = listener
        var address = Self.defaultOutputAddress
        AudioObjectAddPropertyListenerBlock(Self.systemObject, &address, DispatchQueue.main, listener)
        bindDefaultDevice(notify: false)
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        if let systemListener {
            var address = Self.defaultOutputAddress
            AudioObjectRemovePropertyListenerBlock(Self.systemObject, &address, DispatchQueue.main, systemListener)
        }
        systemListener = nil
        unbindDevice()
        output = nil
    }

    /// Re-reads the default device (after wake).
    func refresh() {
        guard isStarted else { return }
        bindDefaultDevice(notify: false)
    }

    // MARK: - Reading & writing

    var volume: Float? {
        guard let output else { return nil }
        var address = Self.volumeAddress()
        guard AudioObjectHasProperty(output.id, &address) else { return nil }
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(output.id, &address, 0, nil, &size, &value)
        return status == noErr ? min(max(value, 0), 1) : nil
    }

    var isMuted: Bool {
        guard let output, output.hasMute else { return false }
        var address = Self.muteAddress()
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(output.id, &address, 0, nil, &size, &value)
        return status == noErr && value != 0
    }

    @discardableResult
    func setVolume(_ level: Float) -> Bool {
        guard let output, output.canSetVolume else { return false }
        var address = Self.volumeAddress()
        var value = Float32(min(max(level, 0), 1))
        let size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectSetPropertyData(output.id, &address, 0, nil, size, &value)
        if status == noErr, value > 0, isMuted {
            setMuted(false)
        }
        return status == noErr
    }

    @discardableResult
    func setMuted(_ muted: Bool) -> Bool {
        guard let output, output.hasMute else { return false }
        var address = Self.muteAddress()
        var value = UInt32(muted ? 1 : 0)
        let size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectSetPropertyData(output.id, &address, 0, nil, size, &value) == noErr
    }

    // MARK: - Device binding

    private func bindDefaultDevice(notify: Bool) {
        let deviceID = Self.defaultOutputDevice()
        if deviceID == output?.id, !deviceListeners.isEmpty {
            return
        }
        unbindDevice()
        guard deviceID != AudioObjectID(kAudioObjectUnknown) else {
            output = nil
            if notify { onOutputChange?(nil) }
            return
        }
        let newOutput = Self.describe(deviceID)
        output = newOutput

        let valueListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.levelChanged()
            }
        }
        let sourceListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.dataSourceChanged()
            }
        }
        addDeviceListener(Self.volumeAddress(), valueListener, on: deviceID)
        addDeviceListener(Self.muteAddress(), valueListener, on: deviceID)
        addDeviceListener(Self.dataSourceAddress(), sourceListener, on: deviceID)

        lastLevel = volume
        lastMuted = isMuted
        if notify { onOutputChange?(newOutput) }
    }

    private func addDeviceListener(_ address: AudioObjectPropertyAddress, _ block: @escaping AudioObjectPropertyListenerBlock, on deviceID: AudioObjectID) {
        var mutableAddress = address
        guard AudioObjectHasProperty(deviceID, &mutableAddress) else { return }
        let status = AudioObjectAddPropertyListenerBlock(deviceID, &mutableAddress, DispatchQueue.main, block)
        if status == noErr {
            deviceListeners.append((address, block))
        }
    }

    private func unbindDevice() {
        guard let deviceID = output?.id else {
            deviceListeners.removeAll()
            return
        }
        for (address, block) in deviceListeners {
            var mutableAddress = address
            AudioObjectRemovePropertyListenerBlock(deviceID, &mutableAddress, DispatchQueue.main, block)
        }
        deviceListeners.removeAll()
    }

    private var lastLevel: Float?
    private var lastMuted = false

    /// Volume listeners can fire once per channel; only real changes pass.
    private func levelChanged() {
        guard let level = volume else { return }
        let muted = isMuted
        if let lastLevel, abs(lastLevel - level) < 0.0005, muted == lastMuted { return }
        lastLevel = level
        lastMuted = muted
        onVolumeChange?(level, muted)
    }

    /// Headphones plugged into / removed from the built-in jack.
    private func dataSourceChanged() {
        guard let deviceID = output?.id else { return }
        let updated = Self.describe(deviceID)
        guard updated != output else { return }
        output = updated
        onOutputChange?(updated)
    }

    // MARK: - Static helpers

    private static func defaultOutputDevice() -> AudioObjectID {
        var address = defaultOutputAddress
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &deviceID)
        return status == noErr ? deviceID : AudioObjectID(kAudioObjectUnknown)
    }

    private static func describe(_ deviceID: AudioObjectID) -> Output {
        var volume = volumeAddress()
        var settable = DarwinBoolean(false)
        let hasVolume = AudioObjectHasProperty(deviceID, &volume)
            && AudioObjectIsPropertySettable(deviceID, &volume, &settable) == noErr
            && settable.boolValue
        var mute = muteAddress()
        let hasMute = AudioObjectHasProperty(deviceID, &mute)
        let transport = uint32Property(deviceID, selector: kAudioDevicePropertyTransportType, scope: kAudioObjectPropertyScopeGlobal)
        let dataSource = uint32Property(deviceID, selector: kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput)
        let isBluetooth = transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
        // 'hdpn': headphones on the built-in output.
        let isHeadphoneJack = dataSource == AEType.code("hdpn")
        return Output(
            id: deviceID,
            name: name(of: deviceID) ?? "Output",
            isHeadphones: isBluetooth || isHeadphoneJack,
            canSetVolume: hasVolume,
            hasMute: hasMute
        )
    }

    private static func uint32Property(_ deviceID: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    private static func name(of deviceID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &name) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value = name?.takeRetainedValue() else { return nil }
        return value as String
    }
}
