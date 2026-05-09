import Foundation

// Where the PCM that gets fed to ASR comes from.
//
// `.bleDevice` is the original path: the hardware PTT puck streams SBC over
// GATT; the device's physical button drives streamStart/streamStop packets,
// the app decodes audio and accumulates into sessionPCMBuffer.
//
// `.systemMicrophone` taps AVAudioEngine.inputNode on the Mac, resamples to
// 16 kHz mono PCM16, and uses a global "hold Ctrl" hotkey (PTTHotkeyMonitor)
// as the lifecycle trigger. The BLE device firmware also emits a Ctrl HID
// keycode on its physical button, so the same hotkey path serves both
// "standalone Mac" and "BLE puck button" when in this mode.
public enum InputSource: String, CaseIterable, Codable, Identifiable, Sendable {
    case bleDevice
    case systemMicrophone

    public static let `default`: InputSource = .bleDevice

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .bleDevice:        return "BLE 设备"
        case .systemMicrophone: return "系统麦克风"
        }
    }

    public var helpText: String {
        switch self {
        case .bleDevice:
            return "由 BLE 设备的物理 PTT 按键触发，音频从设备 GATT 推送过来。"
        case .systemMicrophone:
            return "按住 Control 键说话；松开自动转录。Mac 麦克风采集，120 秒上限。"
        }
    }
}
