# Third-Party Software Notices

PTT Voice is licensed under the [MIT License](LICENSE). This document lists
third-party software used by the project, their authors, and the licenses
under which they are distributed.

---

## Vendored source

### LTSBCDecoder — Bluetooth SBC reference decoder

`Sources/LTSBCDecoder/oi/` contains the Bluetooth SBC reference decoder from
the Android Open Source Project (originally written by Open Interface North
America). The PTT BLE puck transmits 32-byte SBC frames over GATT; this
decoder turns them into 16 kHz mono PCM that the rest of the app consumes.

```
Copyright (C) 2014 The Android Open Source Project
Copyright 2003 - 2004 Open Interface North America, Inc. All rights reserved.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at:

    http://www.apache.org/licenses/LICENSE-2.0
```

The decoder code in `Sources/LTSBCDecoder/oi/include/` and
`Sources/LTSBCDecoder/oi/srce/` retains its original Apache 2.0 file headers
unmodified.

`Sources/LTSBCDecoder/LTSBCDecoder.m`, `LTSBCDecoder.h`, and the `shim/`
header stubs that adapt the reference decoder to a SwiftPM target are
licensed under the same MIT license as the rest of this project.

---

## Swift Package Manager dependencies

All dependencies are pulled at build time via SwiftPM. Each project ships its
own `LICENSE` file in its repository; the entries below are summaries with
links.

### Direct

| Package | Repository | License |
| --- | --- | --- |
| speech-swift | https://github.com/soniqo/speech-swift | Apache 2.0 |

### Transitive (via speech-swift)

#### Apple Swift ecosystem — Apache 2.0

* swift-algorithms, swift-argument-parser, swift-asn1,
  swift-async-algorithms, swift-atomics, swift-certificates,
  swift-collections, swift-configuration, swift-crypto,
  swift-distributed-tracing, swift-http-structured-headers,
  swift-http-types, swift-log, swift-metrics, swift-nio,
  swift-nio-extras, swift-nio-transport-services,
  swift-service-context, swift-service-lifecycle, swift-system,
  swift-websocket — all <https://github.com/apple/...>

#### Apple ML Research

* [mlx-swift](https://github.com/ml-explore/mlx-swift) — MIT

#### Hugging Face

* [swift-transformers](https://github.com/huggingface/swift-transformers) — Apache 2.0
* [swift-jinja](https://github.com/huggingface/swift-jinja) — Apache 2.0
* [swift-huggingface](https://github.com/huggingface/swift-huggingface) — Apache 2.0

#### Hummingbird project — Apache 2.0

* [hummingbird](https://github.com/hummingbird-project/hummingbird)
* [hummingbird-websocket](https://github.com/hummingbird-project/hummingbird-websocket)

#### swift-server — Apache 2.0

* [async-http-client](https://github.com/swift-server/async-http-client)

#### Individual contributors

* [adam-fowler/compress-nio](https://github.com/adam-fowler/compress-nio) — Apache 2.0
* [mattt/EventSource](https://github.com/mattt/EventSource) — MIT

#### C libraries

* [yyjson](https://github.com/ibireme/yyjson) (vendored as a SwiftPM target by an upstream package) — MIT

---

## Models

PTT Voice runs the [Qwen3-ASR](https://huggingface.co/Qwen/Qwen3-ASR-1.7B)
speech-recognition model fully on-device via MLX. Two MLX-quantized variants
are downloaded on first use:

* `aufklarer/Qwen3-ASR-0.6B-MLX-4bit`
* `aufklarer/Qwen3-ASR-1.7B-MLX-8bit` (default)

The base model is licensed under [Apache 2.0](https://huggingface.co/Qwen/Qwen3-ASR-1.7B/blob/main/LICENSE).
The MLX-quantized weights inherit the same license.

---

## Reporting

If you believe a third-party license obligation has been missed in this
project, please open an issue.
