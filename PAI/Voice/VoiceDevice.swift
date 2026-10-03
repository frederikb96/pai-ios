import AVFoundation
import PAIKit
import UIKit

/// This phone and the microphone it is recording from right now — what labels a backend debug
/// recording and a wake-word sample run with the device and headset that produced them.
enum VoiceDevice {
    @MainActor
    static func current() -> VoiceDeviceInfo {
        VoiceDeviceInfo(name: deviceName, mic: currentMicrophone)
    }

    @MainActor
    static var deviceName: String {
        "\(UIDevice.current.model) · iOS \(UIDevice.current.systemVersion)"
    }

    /// The input port's uid — stable across a headset's profile switches, unlike its name or format.
    static var currentMicrophoneId: String? {
        AVAudioSession.sharedInstance().currentRoute.inputs.first?.uid
    }

    static var currentMicrophone: String? {
        AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName
    }
}
