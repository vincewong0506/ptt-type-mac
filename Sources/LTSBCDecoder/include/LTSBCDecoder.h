#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const LTSBCDecoderErrorDomain;

typedef NS_ENUM(NSInteger, LTSBCDecoderErrorCode) {
    LTSBCDecoderErrorCodeInitFailed = 1,
    LTSBCDecoderErrorCodeInvalidFrameLength = 2,
    LTSBCDecoderErrorCodeDecodeFailed = 3,
    LTSBCDecoderErrorCodeUnexpectedOutputLength = 4,
};

/// Mono 16 kHz / 8 subbands / 16 blocks / bitpool 12 SBC frame size used by
/// the ESP32-S3 firmware. One encoded frame is 32 bytes, decoding to 128
/// PCM16 samples (256 bytes, 8 ms of audio at 16 kHz).
FOUNDATION_EXPORT NSInteger const LTSBCDecoderEncodedFrameLength;
FOUNDATION_EXPORT NSInteger const LTSBCDecoderPCMSamplesPerFrame;
FOUNDATION_EXPORT NSInteger const LTSBCDecoderPCMBytesPerFrame;

/// Thin wrapper over the OI SBC decoder vendored from ESP-IDF bluedroid.
/// Configured for the firmware's fixed parameters (mono / 16 kHz / 8 subbands
/// / 16 blocks / bitpool 12). Single-threaded — the caller serialises decode
/// calls from the BLE pipeline.
@interface LTSBCDecoder : NSObject

- (nullable instancetype)initWithError:(NSError * _Nullable * _Nullable)error NS_DESIGNATED_INITIALIZER NS_SWIFT_NAME(init());

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

/// Re-initialise the decoder context. Call when the BLE stream restarts
/// (STREAM_START) so internal filter state is wiped.
- (BOOL)resetWithError:(NSError * _Nullable * _Nullable)error NS_SWIFT_NAME(reset());

/// Decode one 32-byte SBC frame into 256 bytes (128 samples) of PCM16. Returns
/// nil on failure with `error` populated.
- (nullable NSData *)decodeFrame:(NSData *)sbcFrame
                           error:(NSError * _Nullable * _Nullable)error NS_SWIFT_NAME(decode(_:));

@end

NS_ASSUME_NONNULL_END
