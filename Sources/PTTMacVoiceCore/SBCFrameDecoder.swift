import Foundation
import LTSBCDecoder

final class SBCFrameDecoder {
    private var decoder: LTSBCDecoder?

    func reset() {
        guard let decoder else { return }
        do {
            try decoder.reset()
        } catch {
            self.decoder = nil
        }
    }

    func decode(frames: [Data]) throws -> Data {
        let decoder = try ensureDecoder()
        var pcm = Data()
        pcm.reserveCapacity(frames.count * Int(LTSBCDecoderPCMBytesPerFrame))

        for frame in frames {
            let decoded = try decoder.decode(frame)
            pcm.append(decoded)
        }

        return pcm
    }

    private func ensureDecoder() throws -> LTSBCDecoder {
        if let decoder {
            return decoder
        }
        let decoder = try LTSBCDecoder()
        self.decoder = decoder
        return decoder
    }
}
