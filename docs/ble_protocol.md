# BLE Push-to-Talk Voice Protocol

> **Note for readers of the open-source Mac client.** This document was
> authored alongside the BLE puck firmware (a separate, currently private
> repo) and is the shared source of truth for the GATT service /
> characteristic layout, packet format, opcode set, and stream-state
> machine that `BLEVoiceClient.swift` parses on the Mac side. Sections
> referencing internal firmware components (`components/ble_voice/`,
> NimBLE, ESP32 GPIO wiring, etc.) are background context — they don't
> affect what the Mac client needs to implement, but they explain why
> the protocol is shaped the way it is. The original Chinese title and
> body are kept verbatim to avoid drift between the two sides.

# BLE 本地 Mic Push-to-Talk 语音流 -> iOS App：协议设计

## Context

**要解决的问题**：ESP32-S3-Touch-AMOLED-1.8 设备本地采集 Mic 音频。用户在 Mic 页面按住 Mic 图标时开始录音，松开后停止录音，也就是 Push-to-Talk 逻辑。设备需要通过 **BLE** 把这段本地 Mic 语音实时传给配套的 **iOS App**，由 iOS App 做解码和 ASR。

**本次范围**：聚焦 BLE 语音传输协议本身，包括 GATT service/characteristic、字节级包格式、opcode 集合、状态机、iOS 侧消费方式和验证路径。设备侧 SBC encoder/decoder、BLE service 代码、音频采集路径按阶段推进。

**硬件事实**：
- ESP32-S3 只支持 Bluetooth LE，不支持经典蓝牙，也不支持 HFP/SCO。
- 本项目语音来源是本地 ES8311 Mic，经 I2S 采集，Mic 页面的本地录音文件使用 16 kHz / mono / SBC raw frame 存储，用于验证 SBC 编码和解码闭环。
- 因此本文档中所有语音均指 **本地 Mic uplink**，不是 HFP downlink，不涉及经典蓝牙通话音频。

**协议设计目标**：
- 尽量沿用原有 BLE audio datapath 协议结构。
- 音频 payload 仍使用 `AUDIO_SBC`，iOS 端继续按 SBC 帧解码。
- 设备侧把本地 Mic PCM 编码成固定参数 SBC 后再发送。

**SBC 传输参数（目标）**：
- 输入 PCM：16 kHz / mono / 16-bit
- SBC：16 kHz / mono / bitpool=12 / 16 blocks / 8 subbands
- 目标帧长：**32 bytes/frame**
- 帧率：**125 fps**
- 码率：**4 kB/s**

> 重要说明：协议层可以与原设计保持一致，继续使用 `AUDIO_SBC`。当前工程已加入 `components/ble_sbc`，把本地 Mic PCM 编码为上述固定 32 字节 SBC frame。

**当前工程状态**：
- BLE 使用 NimBLE。
- `components/ble_voice/` 已实现 BLE Peripheral / GATT Server、advertising fields、CCCD 订阅状态、连接句柄、MTU 记录、RX command parser 和 TX Notify 数据通路；固件默认不启动 BLE，用户在 BLE 页面启用后才初始化协议栈并开始广播。
- Mic 按下时若 `enabled && connected && subscribed && !disarmed && mtu_frames >= 1`，录音任务把 SBC frame 直接送入 BLE Notify；否则写入本地 `/spiffs/voice.sbc`，本地仍只保留最近一条。

**设计决策**：
1. **开流触发**：`CCCD subscribed && ptt_recording && !disarmed`，即 iOS 订阅 TX Notify 后，用户按住 Mic 开始推流。
2. **停流触发**：用户松开 Mic、BLE 断开、iOS 写 `CMD_DISARM`、或发生错误。
3. **预滚**：不预滚。进入 streaming 时清空 ringbuf，从下一帧开始发送。
4. **广播 UUID**：把 Voice Service UUID 放进 BLE 广播或 Scan Response，方便 iOS 后台按 service UUID 扫描。
5. **UUID 策略**：使用项目自定义 128-bit UUID，不使用 SIG 16-bit UUID，也不复用其他厂商占位 UUID。

---

## UUID 分配

| 实体 | UUID | 属性 |
|------|------|------|
| **Service** | `a07c2b76-1b8c-492b-acef-51b5d02cf54a` | Primary |
| **TX Characteristic** | `a07c2b76-1b8c-492b-acef-51b5d02cf54b` | Notify + CCCD |
| **RX Characteristic** | `a07c2b76-1b8c-492b-acef-51b5d02cf54c` | Write + WriteWithoutResponse |

**小端字节序（C 数组格式）**：

```c
// Service UUID: a07c2b76-1b8c-492b-acef-51b5d02cf54a
#define BLE_VOICE_SERVICE_UUID \
    0x4a,0xf5,0x2c,0xd0,0xb5,0x51,0xef,0xac,0x2b,0x49,0x8c,0x1b,0x76,0x2b,0x7c,0xa0

// TX Char UUID: a07c2b76-1b8c-492b-acef-51b5d02cf54b (Notify)
#define BLE_VOICE_TX_CHAR_UUID \
    0x4b,0xf5,0x2c,0xd0,0xb5,0x51,0xef,0xac,0x2b,0x49,0x8c,0x1b,0x76,0x2b,0x7c,0xa0

// RX Char UUID: a07c2b76-1b8c-492b-acef-51b5d02cf54c (Write)
#define BLE_VOICE_RX_CHAR_UUID \
    0x4c,0xf5,0x2c,0xd0,0xb5,0x51,0xef,0xac,0x2b,0x49,0x8c,0x1b,0x76,0x2b,0x7c,0xa0
```

**iOS 端常量**：

```swift
let kSvcUUID = CBUUID(string: "A07C2B76-1B8C-492B-ACEF-51B5D02CF54A")
let kTxUUID  = CBUUID(string: "A07C2B76-1B8C-492B-ACEF-51B5D02CF54B")
let kRxUUID  = CBUUID(string: "A07C2B76-1B8C-492B-ACEF-51B5D02CF54C")
```

**广播中的 Service UUID TLV**：128-bit UUID 的 AD type 是 `0x07`（Complete List of 128-bit Service UUIDs），payload 是 16 字节小端 UUID。AD structure 总长 18 字节，其中 `len = 0x11` 表示后续 `type + uuid` 共 17 字节：

```text
len   type  uuid (LE, 16 B)
0x11  0x07  4a f5 2c d0 b5 51 ef ac 2b 49 8c 1b 76 2b 7c a0
```

Legacy 广播总预算只有 31 字节，128-bit UUID 会占掉 18 字节。若广告包放不下，可把 Service UUID 放到 Scan Response。iOS 前台扫描通常可以看到 Scan Response；后台扫描则需要实测确认。

---

## 总体架构

```text
iOS App                      BLE Link                  ESP32-S3 device
─────────                    ────────                  ───────────────
CBCentralManager
  scan w/ SVC filter   ←────── ADV / ScanRsp ───────── GAP advertiser
  connect              ──────── CONNECT_REQ ─────────→
  discoverServices     ←──── Service Discovery ───────
  exchangeMTU          ←──── MTU Exchange ───────────→  MTU ~= 185 typical
  setNotifyValue YES   ──────── CCCD = 1 ────────────→  cccd_on = true

用户按住 Mic ───────────────────────────────────────→  ptt_recording = true
                                                       ringbuf reset
                                                       SBC encoder start
  didUpdateValueFor    ←────── NOTIFY 0x01 START ───── STREAM_START
  didUpdateValueFor    ←────── NOTIFY 0x10 AUDIO ───── AUDIO_SBC x25/s
       ↓
    parse header -> SBC decode -> PCM(local mic) -> ASR

用户松开 Mic ───────────────────────────────────────→  ptt_recording = false
  didUpdateValueFor    ←────── NOTIFY 0x02 STOP ────── STREAM_STOP
```

**两条 GATT 特征职责**：
- **TX Char（Notify，设备 -> iOS）**：音频和遥测，包括 `STREAM_START` / `AUDIO_SBC` / `STREAM_STOP` / `HEARTBEAT` / `OVERFLOW_WARN` / `STATUS_RSP`
- **RX Char（Write，iOS -> 设备）**：控制命令，包括查询状态、暂停/恢复推流、ping

---

## 协议规范

### 1. 公共包头（4 字节）

```text
offset  size  field
   0     1    opcode
   1     1    flags         // bit0 = last-in-burst; bits1..3 = version(current=0); rest reserved
   2     2    seq (LE)      // 16-bit monotonic, wraps naturally
```

**Seq 语义**：
- TX 侧每发一个 notification 递增一次，音频和控制共享同一 seq 空间。
- 每次 `STREAM_START` 时把 seq 重置为 0。
- iOS 端按 `(seq - last_seq) & 0xFFFF != 1` 判断 gap。
- 16-bit 在 25 notif/s 下约 44 分钟回绕，客户端必须用模运算兼容。

**Flags.bit0**：同一次 batch flush 的最后一个包置 1。当前每次 flush 只发一个包，因此总是 1；保留给未来分片。

### 2. TX Opcodes（设备 -> iOS）

| Opcode | 名称 | Payload 长度 | Payload 格式 |
|--------|------|-------------|-------------|
| `0x01` | `STREAM_START` | 12 | `u8 codec=1(SBC), u8 sr_khz=16, u8 ch=1, u8 bitpool=12, u8 blocks=16, u8 subbands=8, u16_le frame_bytes=32, u32_le epoch_ms` |
| `0x02` | `STREAM_STOP` | 1 | `u8 reason`，0=ptt_release, 1=disconnect, 2=error, 3=host_req |
| `0x10` | `AUDIO_SBC` | 2 + n*32 | `u8 n_frames, u8 reserved=0, sbc_frame[0..n-1][32]` |
| `0x20` | `HEARTBEAT` | 16 | `u32_le uptime_ms, u32_le fed_frames_or_pong_nonce, u32_le sent_frames, u32_le overflow_frames` |
| `0x21` | `OVERFLOW_WARN` | 6 | `u16_le dropped_since_last, u32_le total_dropped` |
| `0x2F` | `STATUS_RSP` | 6 | `u8 state(0=idle/1=armed/2=streaming), u8 ptt_recording, u8 cccd_on, u8 mtu_frames, u16_le negotiated_mtu` |

**补充语义**：
- `STREAM_START` 在 streaming 门打开那一刻发，只发一次。
- `STREAM_STOP` 在 streaming 门关闭时发一次。
- `HEARTBEAT` 仅在 streaming 期间作为低频保活发送，或在 iOS 写 `CMD_PING` 时按需返回；空闲连接不做周期性 Notify，避免不必要功耗和日志噪声。
- `OVERFLOW_WARN` 只在丢帧时发送，最快 100 ms 一次节流。

### 3. RX Opcodes（iOS -> 设备）

| Opcode | 名称 | Payload 长度 | Payload 格式 |
|--------|------|-------------|-------------|
| `0x80` | `CMD_QUERY_STATE` | 0 | 空，设备立即回 `STATUS_RSP` |
| `0x81` | `CMD_DISARM` | 0 | 空，临时停流，保留连接/订阅 |
| `0x82` | `CMD_REARM` | 0 | 空，取消 DISARM，恢复自动开流门 |
| `0x84` | `CMD_PING` | 4 | `u32_le nonce`，设备回 `HEARTBEAT`，flags.bit1 置 1，`fed_frames_or_pong_nonce` 字段填同一个 nonce |

**DISARM/REARM**：主触发是 PTT，但 iOS App 可能希望暂时不接收音频，例如后台策略、用户关闭转写、低电量模式。`DISARM` 会让设备保持 BLE 连接和订阅状态，但停止发送 `AUDIO_SBC`；iOS 可通过 `CMD_PING` 主动确认链路。

### 4. 开流状态机（设备侧）

```text
                      ┌──────────┐
                      │   IDLE   │←──────────────┐
                      └────┬─────┘               │
                           │                     │
        cccd_on && !disarmed && !ptt_recording   │
                           │                     │
                      ┌────▼─────┐               │
                      │  ARMED   │               │
                      └────┬─────┘               │
                           │                     │
                    ptt_recording                │ disconnect /
                           │                     │ ptt_release /
                      ┌────▼──────┐              │ disarm /
                      │ STREAMING │──────────────┘ error
                      └───────────┘
```

进入 STREAMING：
- seq 清零
- 清空 PCM/SBC ringbuf
- 启动或打开 SBC encoder 输入
- 发送 `STREAM_START`
- 清零 overflow 统计

离开 STREAMING：
- 停止消费 audio ringbuf
- 发送 `STREAM_STOP(reason)`
- 保留 BLE 连接和 CCCD 状态

**三个门条件**：`cccd_on && ptt_recording && !disarmed`。任一为假立即退出 STREAMING。

### 5. 批量打包与 MTU 适配

SBC 每帧 32 字节、125 fps。如果每帧发一个 notification，就是 125 notif/s。按 MTU 聚合多帧：

```text
att_payload   = mtu - 3
available     = att_payload - 4 - 2
mtu_frames    = clamp(available / 32, 1, 5)
```

| MTU | att_payload | 可用 | mtu_frames | notify rate |
|-----|-------------|------|-----------|-------------|
| 23  | 20          | 14   | 1         | 125/s |
| 104 | 101         | 95   | 2         | ~63/s |
| 185 | 182         | 176  | 5         | 25/s |
| 251 | 248         | 242  | 5         | 25/s |

**启动时序**：连接建立后 MTU 交换通常在 100-300 ms 内完成。为避免 MTU=23 时开流造成 notification 风暴，设备侧应等到首次 MTU 更新事件，或 500 ms 超时后再允许 `STREAM_START`。

**Batch flush 条件**：
- `batch.n >= mtu_frames`
- 从 batch 第一帧入列起 20 ms 已过

### 6. 流控

目标音频码率 4 kB/s，BLE 链路足够承载，但仍需要防止 TX 队列堆积：

- 维护 `inflight` 计数器：每次 notify 成功入队递增，每次 TX complete 递减。
- 上限 2：若 `inflight >= 2`，新的 AUDIO batch 不发，丢弃该 batch，`dropped_since_last += n_frames_in_batch`。
- 下一次可发送时补发 `OVERFLOW_WARN`，最快 100 ms 一次。
- ringbuf 溢出也累计到同一 overflow 统计。

---

## 示例包

```text
STREAM_START  (总 16 字节)
  hdr:   01 00 00 00
  pld:   01 10 01 0C 10 08
         20 00
         A0 86 01 00

AUDIO_SBC 5 frames (总 166 字节)
  hdr:   10 01 07 00
  pld:   05 00
         <5 * 32 B SBC raw data>

STREAM_STOP (总 5 字节)
  hdr:   02 01 F3 12
  pld:   00

STATUS_RSP (总 10 字节)
  hdr:   2F 01 01 00
  pld:   02 01 01 05 B9 00
```

---

## iOS App 侧消费指南

### 发现与连接

1. `Info.plist` 加 `UIBackgroundModes = [bluetooth-central]` 和 `NSBluetoothAlwaysUsageDescription`
2. `CBCentralManager(delegate:queue:options:)` 可加 restore identifier
3. `scanForPeripherals(withServices: [kSvcUUID], options: nil)`
4. `didDiscover` -> `connect` -> `discoverServices([kSvcUUID])` -> `discoverCharacteristics([kTxUUID, kRxUUID])`
5. `setNotifyValue(true, for: txChar)` 触发设备端 CCCD_ON

### 接收状态机

```swift
class BleVoiceParser {
    var lastSeq: UInt16?
    var sbcDecoder: SbcDecoder?

    func handle(_ data: Data) {
        guard data.count >= 4 else { return }
        let opcode = data[0]
        let flags  = data[1]
        let seq    = UInt16(data[2]) | (UInt16(data[3]) << 8)
        let pld    = data.subdata(in: 4..<data.count)

        if let ls = lastSeq, UInt16((seq &- ls)) != 1 {
            logGap(expected: ls &+ 1, got: seq)
        }
        lastSeq = seq

        switch opcode {
        case 0x01: handleStart(pld)    // 初始化 SBC decoder
        case 0x02: handleStop(pld)     // flush decoder + 结束当前 ASR 片段
        case 0x10: handleAudio(pld)    // n=pld[0]，pld[2...] 按 32 字节切帧
        case 0x20: handleHeartbeat(pld)
        case 0x21: handleOverflow(pld)
        case 0x2F: handleStatus(pld)
        default: break
        }
    }
}
```

---

## 验证路径

### Stage 1 — nRF Connect 验证 BLE service

1. 烧板，打开 BLE 页面并启用 BLE。
2. nRF Connect 扫描，预期看到设备广播，广播或 Scan Response 含 Service UUID `a07c2b76-1b8c-492b-acef-51b5d02cf54a`。
3. 连接设备，发现 TX/RX characteristic。
4. 启用 TX Notify。
5. 写 `80 00 00 00` 到 RX Char，预期收到 `STATUS_RSP`，其中 `ptt_recording=0, cccd_on=1`。
6. 在设备 Mic 页面按住 Mic：
   - 收到 `STREAM_START`
   - 收到稳定 `AUDIO_SBC`，目标约 25 notif/s，每包约 166 字节
   - `STATUS_RSP` 显示 `state=streaming`
7. 松开 Mic，预期收到 `STREAM_STOP reason=0`。

### Stage 2 — PC 离线解码

1. 从 nRF Connect 导出 notification log。
2. 解析 `opcode == 0x10` 的包，取 `pld[2:]`，按 32 字节切 SBC frame，顺序拼成 `out.sbc`。
3. 用 libsbc / `sbcdec` 解码成 WAV，人工确认声音清晰。
4. 把 WAV 喂给 ASR，检查转写效果。

### Stage 3 — iOS 端到端

1. iOS App 前台完成扫描、连接、订阅、解析、SBC decode。
2. 按住 Mic 讲话，实时得到 ASR 文本。
3. 测试快速按下/松开、连续多次 PTT、后台恢复、BLE 断开重连。
4. 长按 5 分钟，观察 `OVERFLOW_WARN` 是否为 0。

---

## 开放问题

1. **iOS SBC decode**：iOS 原生 CoreBluetooth 不负责解码 SBC payload。App 侧需要内置 SBC decoder，或者服务端未来改成 iOS 更容易处理的 PCM/ADPCM/Opus。
2. **MTU 与连接间隔**：iOS 典型 MTU 约 185，但不是硬保证。连接后应记录实际 MTU；当前固件先按单个 32-byte SBC frame / Notify 发送，后续可按 `mtu_frames` 做多帧打包。
3. **广告预算**：128-bit Service UUID 占 18 字节。当前固件把短名和 Service UUID 放在 advertising，完整名放在 scan response；后续若扩展广播字段，可评估 extended advertising。

---

## 关键产物

- 协议文档（本文件）：本地 Mic PTT 语音流、SBC over BLE GATT、字节级格式、状态机、示例包。
- iOS 侧消费伪代码：扫描、连接、订阅、解析、SBC decode。
- 验证步骤：nRF Connect 手动验证 -> PC 离线 SBC 解码 -> iOS 端到端。
