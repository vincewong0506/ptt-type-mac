import Foundation

struct ASRPromptProfile: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var prompt: String
    // Stable key for built-in templates so "Reset to template" can locate the
    // original content even after the user renames the profile. nil = pure
    // user-created profile with no template to fall back to.
    var builtInKey: String?
    // Whether to run an Apple FoundationModels cleanup pass on the raw
    // transcript before pasting. Per-profile so e.g. a radio-comms profile
    // can keep raw output while the engineering profile gets polished.
    var cleanupEnabled: Bool

    init(
        id: UUID = UUID(),
        name: String,
        prompt: String,
        builtInKey: String? = nil,
        cleanupEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.builtInKey = builtInKey
        self.cleanupEnabled = cleanupEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, prompt, builtInKey, cleanupEnabled
    }

    // Custom decoder so old persisted profiles (from before cleanupEnabled
    // existed) decode with cleanupEnabled = true rather than failing.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        prompt = try c.decode(String.self, forKey: .prompt)
        builtInKey = try c.decodeIfPresent(String.self, forKey: .builtInKey)
        cleanupEnabled = try c.decodeIfPresent(Bool.self, forKey: .cleanupEnabled) ?? true
    }
}

enum ASRPromptTemplate {
    struct Template {
        let key: String
        let name: String
        let prompt: String
        let cleanupEnabled: Bool
    }

    static let engineerKey = "engineer"

    // Deprecated builtin keys — kept here as the truth source for the
    // launch-time purge in AppModel.loadPromptProfiles so existing user data
    // gets cleaned up. Don't add new templates with these keys.
    static let deprecatedBuiltinKeys: Set<String> = ["family", "outdoor"]

    static let all: [Template] = [
        Template(
            key: engineerKey,
            name: "软件工程师",
            prompt: """
                说话人是软件工程师，使用普通话与英文技术术语混杂表达，英语发音不一定标准。声学模糊时，优先匹配下方列出的稀有术语；声学清晰时按音频忠实输出，不要被词表干扰。

                【输出规范】
                - 中英文混合时按下方词表保持英文原拼写。
                - 数字使用阿拉伯数字（1000、下午 3 点、120 秒、16 kHz）。
                - 单位与协议保持英文原样（kHz、Mbps、ms、Wi-Fi、USB-C、Bluetooth）。

                【口语清理（不要输出以下内容）】
                - 无意义语气词与停顿音：嗯、啊、呃、唉、哦。
                - 重复结巴：那个那个、就是就是、然后然后、这个这个 等连续重复词。
                - 保留正常口语连接词：然后、所以、不过、但是、其实、那么。
                - 不要输出空白片段或纯停顿，不要把笑声、咳嗽等非语言音转写成文字。

                【关键术语（仅列稀有或易错词；常见英文如 API、HTTP、JSON 不重复）】
                混合大小写（最易被全大写或拆开）：App、Web、Demo、Pod、macOS、iOS、iPadOS、watchOS、AppKit、SwiftUI、SwiftPM、UIKit、TypeScript、JavaScript、HuggingFace、DashScope、PostgreSQL、ChatGPT、MacBook、AirPods、Qwen3-ASR。

                ASR / LLM：prompt bias、hotword、context biasing、beam search、greedy decoding、tokenizer、encoder、decoder、embedding、attention、transformer、quantization、fine-tune、prompt caching、KV cache、code-switching、inference、checkpoint、LoRA、RAG、fp16、bf16、int8、ONNX、GGUF、MLX。

                嵌入式 / PTT 硬件：ESP32、BLE、GATT、MTU、SBC、Opus、I2C、I2S、SPI、UART、NVS、PWM、AXP2101、SX1262、PTT、wakeword、VAD。

                Swift 开发：actor、async、await、closure、optional、binding、observable、Combine、CocoaPods。

                工程通用（声学相似词多、易识错）：debounce、throttle、retry、backoff、polling、websocket、payload、middleware、callback、rebase、cherry-pick、stash、checkout。
                """,
            cleanupEnabled: true
        ),
    ]

    static func template(forKey key: String) -> Template? {
        all.first { $0.key == key }
    }

    static func seedProfiles() -> [ASRPromptProfile] {
        all.map {
            ASRPromptProfile(
                name: $0.name,
                prompt: $0.prompt,
                builtInKey: $0.key,
                cleanupEnabled: $0.cleanupEnabled
            )
        }
    }
}
