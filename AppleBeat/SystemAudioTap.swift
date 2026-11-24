import CoreAudio
import Foundation

/// Listens to everything the Mac plays, through a Core Audio process tap (macOS 14.2+).
/// Nothing is recorded: each buffer is mixed to mono, handed to `onSamples` and dropped.
/// macOS asks once for "System Audio Recording Only" permission.
final class SystemAudioTap {
    enum TapError: LocalizedError {
        case coreAudio(String, OSStatus)
        case unsupportedFormat

        var errorDescription: String? {
            switch self {
            case .coreAudio(let what, let status): "\(what) failed (\(status))"
            case .unsupportedFormat: "Unsupported audio format"
            }
        }
    }

    /// Called on the tap's own queue with mono samples and their sample rate.
    var onSamples: ((UnsafeBufferPointer<Float>, Double) -> Void)?

    private let queue = DispatchQueue(label: "applebeat.audio", qos: .userInteractive)
    private let control = DispatchQueue(label: "applebeat.audio.control")
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var sampleRate = 48_000.0
    private var mono = [Float](repeating: 0, count: 16_384)
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var running = false

    private static var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    /// Starts listening. The first time, macOS asks the user for permission and this waits for
    /// the answer, so the work is done off the main queue; `completion` may be called on any queue.
    func start(completion: @escaping (Error?) -> Void) {
        control.async {
            guard !self.running else { return completion(nil) }
            do {
                try self.build()
            } catch {
                return completion(error)
            }
            self.running = true

            // The aggregate device is clocked by the output device, so rebuild when that changes.
            let listener: AudioObjectPropertyListenerBlock = { _, _ in
                guard self.running else { return }
                self.teardown()
                try? self.build()
            }
            self.deviceListener = listener
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutputAddress, self.control, listener)
            completion(nil)
        }
    }

    func stop() {
        control.async {
            guard self.running else { return }
            self.running = false
            if let listener = self.deviceListener {
                AudioObjectRemovePropertyListenerBlock(
                    AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutputAddress, self.control, listener)
            }
            self.deviceListener = nil
            self.teardown()
        }
    }

    // MARK: - Private

    private func build() throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "AppleBeat"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw TapError.coreAudio("Creating the audio tap", status) }

        do {
            var format = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioTapPropertyFormat,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format)
            guard status == noErr else { throw TapError.coreAudio("Reading the tap format", status) }
            guard format.mFormatID == kAudioFormatLinearPCM,
                  format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  format.mBitsPerChannel == 32 else { throw TapError.unsupportedFormat }
            sampleRate = format.mSampleRate

            let outputUID = try Self.defaultOutputUID()
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "AppleBeat",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                ]],
            ]
            status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
            guard status == noErr else { throw TapError.coreAudio("Creating the listening device", status) }

            status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) {
                [weak self] _, input, _, _, _ in
                self?.receive(input)
            }
            guard status == noErr else { throw TapError.coreAudio("Attaching to the audio", status) }

            status = AudioDeviceStart(aggregateID, procID)
            guard status == noErr else { throw TapError.coreAudio("Starting the audio", status) }
        } catch {
            teardown()
            throw error
        }
    }

    private func teardown() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private func receive(_ input: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = buffers.first, first.mData != nil else { return }

        var frames = 0
        if buffers.count == 1 {
            // Interleaved.
            let channels = max(Int(first.mNumberChannels), 1)
            frames = min(Int(first.mDataByteSize) / (4 * channels), mono.count)
            let samples = first.mData!.assumingMemoryBound(to: Float.self)
            let scale = 1 / Float(channels)
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels { sum += samples[frame * channels + channel] }
                mono[frame] = sum * scale
            }
        } else {
            // One buffer per channel.
            frames = min(Int(first.mDataByteSize) / 4, mono.count)
            for frame in 0..<frames { mono[frame] = 0 }
            var used: Float = 0
            for buffer in buffers {
                guard let data = buffer.mData, Int(buffer.mDataByteSize) / 4 >= frames else { continue }
                let samples = data.assumingMemoryBound(to: Float.self)
                for frame in 0..<frames { mono[frame] += samples[frame] }
                used += 1
            }
            if used > 1 { for frame in 0..<frames { mono[frame] /= used } }
        }

        guard frames > 0 else { return }
        mono.withUnsafeBufferPointer { pointer in
            onSamples?(UnsafeBufferPointer(rebasing: pointer[0..<frames]), sampleRate)
        }
    }

    private static func defaultOutputUID() throws -> String {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &defaultOutputAddress, 0, nil, &size, &device)
        guard status == noErr, device != kAudioObjectUnknown else {
            throw TapError.coreAudio("Finding the output device", status)
        }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid)
        guard status == noErr, let uid else {
            throw TapError.coreAudio("Reading the output device", status)
        }
        return uid.takeRetainedValue() as String
    }
}
