import Foundation
import FoundationModels
import OSLog

// Wraps Apple's on-device FoundationModels to polish raw ASR transcripts:
// strip fillers/stutters, merge self-corrections, fix common English term
// casing. Each cleanup runs in a fresh session so transcripts don't leak
// into each other through conversation history.
final class TranscriptCleaner {
    // Master kill switch. Apple Intelligence is gated on system Region; in
    // China region SystemLanguageModel returns deviceNotEligible (the Apple
    // partnership routes through a separate API not exposed via this
    // framework). Until we have a working path on our target regions we
    // bypass cleanup entirely — the code, prompt, and UI plumbing stay so
    // flipping this back to true re-enables the feature with no further
    // changes.
    static let isEnabled: Bool = false

    enum CleanupError: Error, LocalizedError {
        case unavailable(String)
        case generationFailed(Error)

        var errorDescription: String? {
            switch self {
            case .unavailable(let reason):
                return "Foundation Models unavailable: \(reason)"
            case .generationFailed(let underlying):
                return "Cleanup generation failed: \(underlying.localizedDescription)"
            }
        }
    }

    private let logger = Logger(subsystem: "com.ptt.voice", category: "Cleanup")

    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    static var availabilityDescription: String {
        switch SystemLanguageModel.default.availability {
        case .available:
            return "available"
        case .unavailable(let reason):
            return "unavailable (\(String(describing: reason)))"
        }
    }

    func clean(rawText: String, contextPrompt: String) async throws -> String {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return rawText }

        switch SystemLanguageModel.default.availability {
        case .unavailable(let reason):
            throw CleanupError.unavailable(String(describing: reason))
        case .available:
            break
        }

        let instructions = Self.buildInstructions(contextPrompt: contextPrompt)
        let session = LanguageModelSession {
            instructions
        }

        do {
            let response = try await session.respond(to: rawText)
            return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            logger.error("Foundation Models cleanup failed: \(String(describing: error))")
            throw CleanupError.generationFailed(error)
        }
    }

    private static func buildInstructions(contextPrompt: String) -> String {
        """
        You are a speech transcript cleanup assistant. The user input is the raw output of an automatic speech recognition system on Mandarin speech mixed with English technical terms. Apply the rules below and output only the cleaned text — no explanations, no quotes, no markdown.

        Rules:
        1. 去除填充音和停顿音：嗯、啊、呃、唉、哦。
        2. 合并连续重复结巴：那个那个 → 那个；然后然后 → 然后；就是就是 → 就是。
        3. 处理自我修正：当说话人在句中改口时，只保留修正后的最终说法，丢弃修正前的半句。
        4. 修正常见英文专名大小写：App（不是 APP）、macOS（不是 MacOS 或 MACOS）、iOS、iPadOS、SwiftUI、AppKit、SwiftPM、HuggingFace、ChatGPT、DashScope、Qwen3-ASR、TypeScript、JavaScript、PostgreSQL、MacBook、AirPods。
        5. 数字使用阿拉伯数字（1000、下午 3 点、120 秒）。
        6. 保留正常的口语连接词：然后、所以、不过、但是、其实、那么、就是。
        7. 必要时整理标点使句子可读。不要扩展、改写、翻译或概括内容；不要补充说话人没说的信息。
        8. 如果输入已经干净，原样返回即可。

        Speaker scenario context (use as background to disambiguate domain terms; do not echo it back):
        \(contextPrompt)
        """
    }
}
