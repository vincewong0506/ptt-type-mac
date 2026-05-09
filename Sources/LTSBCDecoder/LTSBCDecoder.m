#import "LTSBCDecoder.h"

#import "oi_codec_sbc.h"
#import "oi_status.h"

NSErrorDomain const LTSBCDecoderErrorDomain = @"LTSBCDecoderErrorDomain";

NSInteger const LTSBCDecoderEncodedFrameLength = 32;
NSInteger const LTSBCDecoderPCMSamplesPerFrame = 128; // 16 blocks * 8 subbands * 1 channel
NSInteger const LTSBCDecoderPCMBytesPerFrame = 256;   // 128 samples * sizeof(int16_t)

@implementation LTSBCDecoder {
    OI_CODEC_SBC_DECODER_CONTEXT _context;
    OI_CODEC_SBC_CODEC_DATA_MONO _codecData;
}

- (nullable instancetype)initWithError:(NSError * _Nullable * _Nullable)error {
    self = [super init];
    if (!self) {
        return nil;
    }

    if (![self resetWithError:error]) {
        return nil;
    }

    return self;
}

- (BOOL)resetWithError:(NSError * _Nullable * _Nullable)error {
    memset(&_context, 0, sizeof(_context));
    memset(&_codecData, 0, sizeof(_codecData));

    OI_STATUS status = OI_CODEC_SBC_DecoderReset(&_context,
                                                 _codecData.data,
                                                 sizeof(_codecData.data),
                                                 /* maxChannels  */ 1,
                                                 /* pcmStride    */ 1,
                                                 /* enhanced     */ FALSE,
                                                 /* msbc_enable  */ FALSE);
    if (!OI_SUCCESS(status)) {
        if (error) {
            *error = [NSError errorWithDomain:LTSBCDecoderErrorDomain
                                         code:LTSBCDecoderErrorCodeInitFailed
                                     userInfo:@{NSLocalizedDescriptionKey:
                [NSString stringWithFormat:@"OI_CODEC_SBC_DecoderReset failed: %d", status]}];
        }
        return NO;
    }

    status = OI_CODEC_SBC_DecoderLimit(&_context, FALSE, SBC_SUBBANDS_8);
    if (!OI_SUCCESS(status)) {
        if (error) {
            *error = [NSError errorWithDomain:LTSBCDecoderErrorDomain
                                         code:LTSBCDecoderErrorCodeInitFailed
                                     userInfo:@{NSLocalizedDescriptionKey:
                [NSString stringWithFormat:@"OI_CODEC_SBC_DecoderLimit failed: %d", status]}];
        }
        return NO;
    }

    return YES;
}

- (nullable NSData *)decodeFrame:(NSData *)sbcFrame
                           error:(NSError * _Nullable * _Nullable)error {
    if ((NSInteger)sbcFrame.length != LTSBCDecoderEncodedFrameLength) {
        if (error) {
            *error = [NSError errorWithDomain:LTSBCDecoderErrorDomain
                                         code:LTSBCDecoderErrorCodeInvalidFrameLength
                                     userInfo:@{NSLocalizedDescriptionKey:
                [NSString stringWithFormat:@"Expected %ld byte SBC frame, got %lu",
                 (long)LTSBCDecoderEncodedFrameLength, (unsigned long)sbcFrame.length]}];
        }
        return nil;
    }

    int16_t pcm[128];
    const OI_BYTE *frame = sbcFrame.bytes;
    OI_UINT32 frameBytes = (OI_UINT32)sbcFrame.length;
    OI_UINT32 pcmBytes = sizeof(pcm);

    OI_STATUS status = OI_CODEC_SBC_DecodeFrame(&_context,
                                                &frame,
                                                &frameBytes,
                                                pcm,
                                                &pcmBytes);
    if (!OI_SUCCESS(status)) {
        if (error) {
            *error = [NSError errorWithDomain:LTSBCDecoderErrorDomain
                                         code:LTSBCDecoderErrorCodeDecodeFailed
                                     userInfo:@{NSLocalizedDescriptionKey:
                [NSString stringWithFormat:@"OI_CODEC_SBC_DecodeFrame failed: %d", status]}];
        }
        return nil;
    }

    if (pcmBytes != (OI_UINT32)LTSBCDecoderPCMBytesPerFrame || frameBytes != 0) {
        if (error) {
            *error = [NSError errorWithDomain:LTSBCDecoderErrorDomain
                                         code:LTSBCDecoderErrorCodeUnexpectedOutputLength
                                     userInfo:@{NSLocalizedDescriptionKey:
                [NSString stringWithFormat:@"Decoder produced %u PCM bytes, %u SBC bytes left",
                 (unsigned)pcmBytes, (unsigned)frameBytes]}];
        }
        return nil;
    }

    return [NSData dataWithBytes:pcm length:pcmBytes];
}

@end
