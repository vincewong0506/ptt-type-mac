import Foundation

enum VoiceUUIDs {
    static let service = "A07C2B76-1B8C-492B-ACEF-51B5D02CF54A"
    static let tx = "A07C2B76-1B8C-492B-ACEF-51B5D02CF54B"
    static let rx = "A07C2B76-1B8C-492B-ACEF-51B5D02CF54C"
}

enum VoiceOpcode: UInt8 {
    case streamStart = 0x01
    case streamStop = 0x02
    case audioSBC = 0x10
    case heartbeat = 0x20
    case overflowWarn = 0x21
    case statusResponse = 0x2F
}

enum VoiceCommand {
    case queryState
    case disarm
    case rearm
    case ping(UInt32)

    var data: Data {
        let opcode: UInt8
        var payload: [UInt8] = []
        switch self {
        case .queryState:
            opcode = 0x80
        case .disarm:
            opcode = 0x81
        case .rearm:
            opcode = 0x82
        case .ping(let nonce):
            opcode = 0x84
            payload.append(UInt8(nonce & 0xFF))
            payload.append(UInt8((nonce >> 8) & 0xFF))
            payload.append(UInt8((nonce >> 16) & 0xFF))
            payload.append(UInt8((nonce >> 24) & 0xFF))
        }
        // Protocol §1: flags.bit0 = last-in-burst. RX commands are always
        // single-packet bursts today, so set it to 1 to match the spec.
        var bytes: [UInt8] = [opcode, 0x01, 0x00, 0x00]
        bytes.append(contentsOf: payload)
        return Data(bytes)
    }
}

struct VoicePacket {
    let opcode: UInt8
    let flags: UInt8
    let sequence: UInt16
    let payload: VoicePayload
}

enum VoicePayload {
    case streamStart(StreamStartInfo)
    case streamStop(StreamStopReason)
    case audioSBC(AudioSBCInfo)
    case heartbeat(HeartbeatInfo)
    case overflow(OverflowInfo)
    case status(StatusInfo)
    case unknown(UInt8, Data)
}

/// Decoded AUDIO_SBC (0x10) payload, protocol §2 says
///   payload[0] = u8 n_frames (1..5)
///   payload[1] = u8 reserved (must be 0; future revisions might overload it)
///   payload[2..] = n_frames × 32-byte SBC frames
struct AudioSBCInfo {
    let frames: [Data]
    let reservedByte: UInt8
    /// Raw payload byte count (header excluded). Carried so the consumer
    /// can log the actual length when `frames` is empty due to a malformed
    /// packet (declared `n_frames` mismatching the payload size, or payload
    /// shorter than the 2-byte mini-header).
    let rawPayloadLength: Int
    /// The `n_frames` byte declared by the device, or 0 if the payload was
    /// too short to even read it.
    let declaredFrameCount: Int
}

struct StreamStartInfo {
    let codec: UInt8
    let sampleRateKHz: UInt8
    let channels: UInt8
    let bitpool: UInt8
    let blocks: UInt8
    let subbands: UInt8
    let frameBytes: UInt16
    let epochMS: UInt32
}

enum StreamStopReason: String {
    case pttRelease
    case disconnect
    case error
    case hostRequest
    case unknown

    init(rawValue: UInt8) {
        switch rawValue {
        case 0: self = .pttRelease
        case 1: self = .disconnect
        case 2: self = .error
        case 3: self = .hostRequest
        default: self = .unknown
        }
    }
}

struct HeartbeatInfo {
    let uptimeMS: UInt32
    let fedFramesOrNonce: UInt32
    let sentFrames: UInt32
    let overflowFrames: UInt32
    /// Mirrors common-header `flags.bit1`: protocol §2 overloads it as the
    /// "this heartbeat is a CMD_PING response" indicator. When true,
    /// `fedFramesOrNonce` carries the nonce we sent on the PING; when false
    /// it's the device's own fed_frames counter.
    let isPongResponse: Bool
}

struct OverflowInfo {
    let droppedSinceLast: UInt16
    let totalDropped: UInt32
}

struct StatusInfo {
    enum RemoteState: String {
        case idle
        case armed
        case streaming
        case unknown
    }

    let state: RemoteState
    let pttRecording: Bool
    let subscribed: Bool
    let mtuFrames: UInt8
    let negotiatedMTU: UInt16
}

enum VoicePacketParser {
    static func parse(_ data: Data) -> VoicePacket? {
        guard data.count >= 4 else { return nil }
        let bytes = [UInt8](data)
        let opcode = bytes[0]
        let flags = bytes[1]
        let sequence = UInt16(bytes[2]) | (UInt16(bytes[3]) << 8)
        let payloadData = data.dropFirst(4)
        let payload = parsePayload(opcode: opcode, flags: flags, data: Data(payloadData))
        return VoicePacket(opcode: opcode, flags: flags, sequence: sequence, payload: payload)
    }

    private static func parsePayload(opcode: UInt8, flags: UInt8, data: Data) -> VoicePayload {
        let bytes = [UInt8](data)
        switch VoiceOpcode(rawValue: opcode) {
        case .streamStart where bytes.count >= 12:
            return .streamStart(StreamStartInfo(
                codec: bytes[0],
                sampleRateKHz: bytes[1],
                channels: bytes[2],
                bitpool: bytes[3],
                blocks: bytes[4],
                subbands: bytes[5],
                frameBytes: le16(bytes, 6),
                epochMS: le32(bytes, 8)
            ))
        case .streamStop where bytes.count >= 1:
            return .streamStop(StreamStopReason(rawValue: bytes[0]))
        case .audioSBC:
            // Protocol §2.0x10: payload is `u8 n_frames + u8 reserved + n*32B`.
            // Minimum legal length is 34 (n=1). The legacy "bare 32B SBC frame
            // per notify" device behaviour is no longer compliant — drop that
            // fallback so a malformed firmware can't slip past unnoticed.
            let frameBytes = 32
            guard bytes.count >= 2 else {
                return .audioSBC(AudioSBCInfo(
                    frames: [],
                    reservedByte: 0,
                    rawPayloadLength: data.count,
                    declaredFrameCount: Int(bytes.first ?? 0)
                ))
            }

            let frameCount = Int(bytes[0])
            let reservedByte = bytes[1]
            let payloadFrameBytes = frameCount * frameBytes
            guard frameCount > 0,
                  data.count == 2 + payloadFrameBytes else {
                return .audioSBC(AudioSBCInfo(
                    frames: [],
                    reservedByte: reservedByte,
                    rawPayloadLength: data.count,
                    declaredFrameCount: frameCount
                ))
            }

            var frames: [Data] = []
            frames.reserveCapacity(frameCount)
            for index in 0..<frameCount {
                let start = 2 + index * frameBytes
                let end = start + frameBytes
                frames.append(data.subdata(in: start..<end))
            }
            return .audioSBC(AudioSBCInfo(
                frames: frames,
                reservedByte: reservedByte,
                rawPayloadLength: data.count,
                declaredFrameCount: frameCount
            ))
        case .heartbeat where bytes.count >= 16:
            return .heartbeat(HeartbeatInfo(
                uptimeMS: le32(bytes, 0),
                fedFramesOrNonce: le32(bytes, 4),
                sentFrames: le32(bytes, 8),
                overflowFrames: le32(bytes, 12),
                isPongResponse: (flags & 0x02) != 0
            ))
        case .overflowWarn where bytes.count >= 6:
            return .overflow(OverflowInfo(
                droppedSinceLast: le16(bytes, 0),
                totalDropped: le32(bytes, 2)
            ))
        case .statusResponse where bytes.count >= 6:
            return .status(StatusInfo(
                state: remoteState(bytes[0]),
                pttRecording: bytes[1] != 0,
                subscribed: bytes[2] != 0,
                mtuFrames: bytes[3],
                negotiatedMTU: le16(bytes, 4)
            ))
        default:
            return .unknown(opcode, data)
        }
    }

    private static func remoteState(_ value: UInt8) -> StatusInfo.RemoteState {
        switch value {
        case 0: .idle
        case 1: .armed
        case 2: .streaming
        default: .unknown
        }
    }

    private static func le16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func le32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }
}

struct VoiceStreamState {
    var remoteState: StatusInfo.RemoteState = .idle
    var audioPacketCount = 0
    var sbcFrameCount = 0
    var lastSequence: UInt16?
    var sequenceGapCount = 0

    mutating func apply(_ packet: VoicePacket) {
        // Firmware resets s_seq=0 at every STREAM_START, so the jump from the
        // previous packet's seq to 0 is expected and is NOT a gap. Skip the
        // gap accounting for STREAM_START and treat it as a fresh baseline.
        let isStreamStart: Bool
        if case .streamStart = packet.payload {
            isStreamStart = true
        } else {
            isStreamStart = false
        }

        if !isStreamStart, let lastSequence {
            let expected = lastSequence &+ 1
            if packet.sequence != expected {
                sequenceGapCount += 1
            }
        }
        lastSequence = packet.sequence

        switch packet.payload {
        case .streamStart:
            remoteState = .streaming
            audioPacketCount = 0
            sbcFrameCount = 0
            sequenceGapCount = 0
        case .streamStop:
            remoteState = .idle
        case .audioSBC(let info):
            audioPacketCount += 1
            sbcFrameCount += info.frames.count
        case .status(let status):
            remoteState = status.state
        default:
            break
        }
    }
}
