import Combine
import CoreAudio
import Foundation

struct AudioOutputDevice: Identifiable, Equatable {
    let uid: String
    let name: String

    var id: String { uid }
}

@MainActor
final class AudioOutputManager: ObservableObject {
    @Published private(set) var availableOutputDevices: [AudioOutputDevice] = []
    @Published private(set) var selectedAudioOutputDeviceUID: String?

    private let settingsStore: SettingsStore
    private var cancellables = Set<AnyCancellable>()

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
        selectedAudioOutputDeviceUID = settingsStore.settings.selectedAudioOutputDeviceUID
        bindSettings()
        refreshAvailableOutputDevices()
    }

    func refreshAvailableOutputDevices() {
        let devices = Self.loadOutputDevices()
        availableOutputDevices = devices

        let savedUID = settingsStore.settings.selectedAudioOutputDeviceUID
        let resolvedUID = devices.contains(where: { $0.uid == savedUID }) ? savedUID : nil

        if selectedAudioOutputDeviceUID != resolvedUID {
            selectedAudioOutputDeviceUID = resolvedUID
        }

        if savedUID != resolvedUID {
            settingsStore.settings.selectedAudioOutputDeviceUID = resolvedUID
        }
    }

    func selectAudioOutputDevice(uid: String?) {
        let resolvedUID = availableOutputDevices.contains(where: { $0.uid == uid }) ? uid : nil
        guard selectedAudioOutputDeviceUID != resolvedUID else { return }
        selectedAudioOutputDeviceUID = resolvedUID
        settingsStore.settings.selectedAudioOutputDeviceUID = resolvedUID
    }

    private func bindSettings() {
        settingsStore.$settings
            .map(\.selectedAudioOutputDeviceUID)
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.refreshAvailableOutputDevices()
            }
            .store(in: &cancellables)
    }

    private static func loadOutputDevices() -> [AudioOutputDevice] {
        let systemObjectID = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        guard let deviceIDs = readAudioObjectIDs(objectID: systemObjectID, address: &address) else {
            return []
        }

        return deviceIDs.compactMap { deviceID in
            guard hasOutputStreams(deviceID: deviceID),
                  let uid = stringProperty(deviceID: deviceID, selector: kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(deviceID: deviceID, selector: kAudioObjectPropertyName) else {
                return nil
            }

            return AudioOutputDevice(uid: uid, name: name)
        }
        .sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private static func hasOutputStreams(deviceID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        guard let streamIDs = readAudioStreamIDs(objectID: deviceID, address: &address) else {
            return false
        }

        return !streamIDs.isEmpty
    }

    private static func stringProperty(deviceID: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var propertySize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?

        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &propertySize,
            &value
        )

        guard status == noErr, let value else { return nil }
        return value.takeUnretainedValue() as String
    }

    private static func readAudioObjectIDs(
        objectID: AudioObjectID,
        address: inout AudioObjectPropertyAddress
    ) -> [AudioObjectID]? {
        readArray(objectID: objectID, address: &address, elementSize: MemoryLayout<AudioObjectID>.stride) { buffer in
            buffer.bindMemory(to: AudioObjectID.self).map { $0 }
        }
    }

    private static func readAudioStreamIDs(
        objectID: AudioObjectID,
        address: inout AudioObjectPropertyAddress
    ) -> [AudioStreamID]? {
        readArray(objectID: objectID, address: &address, elementSize: MemoryLayout<AudioStreamID>.stride) { buffer in
            buffer.bindMemory(to: AudioStreamID.self).map { $0 }
        }
    }

    private static func readArray<T>(
        objectID: AudioObjectID,
        address: inout AudioObjectPropertyAddress,
        elementSize: Int,
        transform: (UnsafeMutableRawBufferPointer) -> [T]
    ) -> [T]? {
        var propertySize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &propertySize)
        guard sizeStatus == noErr, propertySize >= UInt32(elementSize) else {
            return nil
        }

        var storage = [UInt8](repeating: 0, count: Int(propertySize))
        let dataStatus = storage.withUnsafeMutableBytes { buffer -> OSStatus in
            AudioObjectGetPropertyData(
                objectID,
                &address,
                0,
                nil,
                &propertySize,
                buffer.baseAddress!
            )
        }

        guard dataStatus == noErr else { return nil }
        return storage.withUnsafeMutableBytes(transform)
    }
}
