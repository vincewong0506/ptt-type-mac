import Foundation
import CoreBluetooth

struct DiscoveredVoiceDevice: Identifiable, Equatable {
    let id: UUID
    let name: String?
    let rssi: Int
    let discoverySource: String

    var displayName: String {
        name?.isEmpty == false ? name! : id.uuidString
    }
}

enum BLEConnectionState: Equatable {
    case idle
    case scanning
    case connecting
    case connected
    case subscribed
    case failed(String)
}

final class BLEVoiceClient: NSObject, ObservableObject {
    @Published private(set) var connectionState: BLEConnectionState = .idle

    var onDevicesChanged: (([DiscoveredVoiceDevice]) -> Void)?
    var onStateChanged: ((BLEConnectionState) -> Void)?
    var onActiveDeviceChanged: ((UUID?) -> Void)?
    var onPacket: ((VoicePacket) -> Void)?
    var onLog: ((String) -> Void)?

    private let serviceUUID = CBUUID(string: VoiceUUIDs.service)
    private let txUUID = CBUUID(string: VoiceUUIDs.tx)
    private let rxUUID = CBUUID(string: VoiceUUIDs.rx)
    private let lastPeripheralIDKey = "PTTVoice.lastPeripheralID"

    private lazy var central = CBCentralManager(delegate: self, queue: .main)
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var discovered: [UUID: DiscoveredVoiceDevice] = [:]
    private var connectedPeripheral: CBPeripheral? {
        didSet {
            if oldValue?.identifier != connectedPeripheral?.identifier {
                onActiveDeviceChanged?(connectedPeripheral?.identifier)
            }
        }
    }
    private var rxCharacteristic: CBCharacteristic?
    private var fallbackScanWorkItem: DispatchWorkItem?
    private var scanTimeoutWorkItem: DispatchWorkItem?
    private var autoReconnectWorkItem: DispatchWorkItem?
    private var connectTimeoutWorkItem: DispatchWorkItem?
    private var systemOwnedPollTimer: Timer?
    private var keepAliveTimer: Timer?
    private var pendingPing: (nonce: UInt32, sentAt: Date)?
    /// Timestamp of the most recent packet (audio frame, status, pong, …)
    /// received from the peer. Any received packet proves the link is alive,
    /// so the keepalive ping is only needed during silent periods.
    private var lastPacketAt: Date?
    private var pendingStartScan = false
    private var isBroadScanning = false
    private var didAutoConnect = false
    private var userInitiatedDisconnect = false

    /// When BLE drops unexpectedly (supervision timeout, range, etc.) the
    /// firmware immediately re-advertises, but the Mac side otherwise sits
    /// idle until the user clicks Scan. Re-trigger a scan after this delay
    /// so the link recovers without manual intervention.
    var autoReconnectEnabled: Bool = true
    var autoReconnectDelay: TimeInterval = 2.0
    /// Backoff delay used after a full scan window has timed out without
    /// finding the peripheral. Longer than `autoReconnectDelay` so the app
    /// doesn't burn cycles when the device is genuinely offline.
    var scanTimeoutReconnectDelay: TimeInterval = 10.0
    var scanTimeout: TimeInterval = 30.0
    var keepAliveInterval: TimeInterval = 10.0
    var keepAliveTimeout: TimeInterval = 18.0
    /// `central.connect()` has no built-in timeout. When we reach the
    /// peripheral via `retrievePeripherals(withIdentifiers:)` (the "remembered"
    /// path), CB queues a pending connection that hangs forever if the device
    /// no longer advertises with the same identity (BD address rotated, off,
    /// out of range). This watchdog cancels and falls back to a fresh scan.
    /// 15s gives a system-owned peripheral (HID auto-reconnected first) time
    /// to expose its voice service GATT to our connect request.
    var connectTimeout: TimeInterval = 15.0
    /// While scanning, periodically retry the system-owned and remembered
    /// peripheral paths. CoreBluetooth does not deliver advertisements for a
    /// peripheral the system has already connected (e.g. via HID), so a
    /// device that boots while we're scanning is invisible until we ask the
    /// system directly.
    var systemOwnedPollInterval: TimeInterval = 5.0

    override init() {
        super.init()
        _ = central
    }

    func startScan() {
        guard central.state == .poweredOn else {
            if central.state.isTransient {
                pendingStartScan = true
                setState(.scanning)
                onLog?("Bluetooth is \(central.state.description); will scan when ready")
                return
            }
            setState(.failed("Bluetooth is \(central.state.description)"))
            return
        }
        pendingStartScan = false
        discovered.removeAll()
        peripherals.removeAll()
        onDevicesChanged?([])
        isBroadScanning = false
        didAutoConnect = false

        // CoreBluetooth's `scanForPeripherals` will NOT report a peripheral
        // that the system already considers connected — for instance when
        // macOS has paired the ESP32 as a Bluetooth keyboard for HID. The
        // only way to reach such a peripheral from our app is to ask the
        // system for the existing handle by service UUID and connect it
        // directly. Multiple apps can hold parallel logical connections, so
        // HID and our voice service still coexist on the same physical link.
        if connectToSystemOwnedPeripheralIfAvailable() {
            return
        }

        if connectToRememberedPeripheralIfAvailable() {
            return
        }

        central.scanForPeripherals(withServices: [serviceUUID], options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])
        setState(.scanning)
        onLog?("Scanning for Voice Service \(VoiceUUIDs.service)")
        scheduleBroadScanFallback()
        scheduleScanTimeout()
        startSystemOwnedPolling()
    }

    /// While `scanForPeripherals` is running, also poll the system every
    /// `systemOwnedPollInterval` seconds for a peripheral that has become
    /// system-connected (e.g. macOS just auto-reconnected via HID). Such
    /// peripherals never appear in scan results.
    private func startSystemOwnedPolling() {
        stopSystemOwnedPolling()
        let timer = Timer.scheduledTimer(withTimeInterval: systemOwnedPollInterval,
                                         repeats: true) { [weak self] _ in
            self?.systemOwnedPollTick()
        }
        systemOwnedPollTimer = timer
    }

    private func stopSystemOwnedPolling() {
        systemOwnedPollTimer?.invalidate()
        systemOwnedPollTimer = nil
    }

    private func systemOwnedPollTick() {
        guard connectionState == .scanning else {
            stopSystemOwnedPolling()
            return
        }
        if connectToSystemOwnedPeripheralIfAvailable() {
            return
        }
        _ = connectToRememberedPeripheralIfAvailable()
    }

    private func connectToSystemOwnedPeripheralIfAvailable() -> Bool {
        let alreadyConnected = central.retrieveConnectedPeripherals(
            withServices: [serviceUUID]
        )
        guard let peripheral = alreadyConnected.first else {
            return false
        }

        let identifier = peripheral.identifier
        peripherals[identifier] = peripheral
        discovered[identifier] = DiscoveredVoiceDevice(
            id: identifier,
            name: peripheral.name,
            rssi: 0,                     // not exposed for system-owned peers
            discoverySource: "system-owned"
        )
        onDevicesChanged?(discovered.values.sorted { $0.displayName < $1.displayName })

        didAutoConnect = true
        onLog?(
            "Found system-owned peripheral \(peripheral.name ?? identifier.uuidString); "
            + "connecting directly without scanning"
        )
        connect(identifier)
        return true
    }

    private func connectToRememberedPeripheralIfAvailable() -> Bool {
        guard let uuidString = UserDefaults.standard.string(forKey: lastPeripheralIDKey),
              let uuid = UUID(uuidString: uuidString),
              let peripheral = central.retrievePeripherals(withIdentifiers: [uuid]).first else {
            return false
        }

        peripherals[uuid] = peripheral
        discovered[uuid] = DiscoveredVoiceDevice(
            id: uuid,
            name: peripheral.name,
            rssi: 0,
            discoverySource: "remembered"
        )
        onDevicesChanged?(discovered.values.sorted { $0.displayName < $1.displayName })

        didAutoConnect = true
        onLog?(
            "Found remembered peripheral \(peripheral.name ?? uuid.uuidString); "
            + "connecting directly before scanning"
        )
        connect(uuid)
        return true
    }

    func stopScan() {
        pendingStartScan = false
        fallbackScanWorkItem?.cancel()
        fallbackScanWorkItem = nil
        scanTimeoutWorkItem?.cancel()
        scanTimeoutWorkItem = nil
        stopSystemOwnedPolling()
        isBroadScanning = false
        central.stopScan()
        if connectionState == .scanning {
            setState(.idle)
        }
    }

    func connect(_ id: UUID) {
        guard let peripheral = peripherals[id] else {
            onLog?("connect(\(id)) skipped: peripheral not in cache")
            return
        }
        stopKeepAlive()
        stopScan()
        connectedPeripheral = peripheral
        peripheral.delegate = self
        onLog?("Calling CB connect for \(peripheral.name ?? id.uuidString)")
        central.connect(peripheral)
        setState(.connecting)
        scheduleConnectTimeout(for: peripheral)
    }

    private func scheduleConnectTimeout(for peripheral: CBPeripheral) {
        connectTimeoutWorkItem?.cancel()
        let timeout = connectTimeout
        let item = DispatchWorkItem { [weak self, weak peripheral] in
            guard let self, let peripheral else { return }
            // Only fire if we're still waiting for didConnect on this attempt.
            guard self.connectionState == .connecting,
                  self.connectedPeripheral?.identifier == peripheral.identifier else { return }
            self.onLog?("CB connect watchdog: no didConnect after \(Int(timeout))s; cancelling")
            self.central.cancelPeripheralConnection(peripheral)
            self.connectedPeripheral = nil
            self.rxCharacteristic = nil
            self.didAutoConnect = false
            // Keep `lastPeripheralIDKey` — the cached identifier is almost
            // always still valid. The watchdog usually fires because the
            // device is offline or just powering back on (system hasn't
            // exposed the voice GATT yet); a fresh scan + retrieve loop will
            // pick it up via system-owned poll once the device is back.
            self.setState(.idle)
            if self.autoReconnectEnabled {
                self.scheduleAutoReconnect()
            }
        }
        connectTimeoutWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: item)
    }

    private func cancelConnectTimeout() {
        connectTimeoutWorkItem?.cancel()
        connectTimeoutWorkItem = nil
    }

    func disconnect() {
        userInitiatedDisconnect = true
        pendingStartScan = false
        autoReconnectWorkItem?.cancel()
        autoReconnectWorkItem = nil
        cancelConnectTimeout()
        stopSystemOwnedPolling()
        stopKeepAlive()
        if let connectedPeripheral {
            central.cancelPeripheralConnection(connectedPeripheral)
        }
        connectedPeripheral = nil
        rxCharacteristic = nil
        setState(.idle)
    }

    private func scheduleAutoReconnect(delay overrideDelay: TimeInterval? = nil) {
        autoReconnectWorkItem?.cancel()
        let delay = overrideDelay ?? autoReconnectDelay
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Bail if the user kicked off something in the gap (manual scan,
            // disconnect, etc.) — only auto-reconnect from recoverable states.
            guard self.connectionState == .idle || self.connectionState.isFailed else { return }
            self.onLog?("Auto-reconnect: re-scanning")
            self.startScan()
        }
        autoReconnectWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        onLog?("Will auto-reconnect in \(Int(delay))s")
    }

    private func startKeepAlive() {
        stopKeepAlive()
        pendingPing = nil
        lastPacketAt = Date()
        let timer = Timer.scheduledTimer(withTimeInterval: keepAliveInterval, repeats: true) { [weak self] _ in
            self?.keepAliveTick()
        }
        keepAliveTimer = timer
        onLog?("BLE keepalive started")
    }

    private func stopKeepAlive() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
        pendingPing = nil
        lastPacketAt = nil
    }

    private func keepAliveTick() {
        guard connectionState == .subscribed else {
            stopKeepAlive()
            return
        }

        // Any incoming packet within the timeout window proves the link is
        // alive — most importantly audio frames during a PTT stream, which
        // saturate BLE bandwidth and can starve a ping/pong round-trip.
        // Recent traffic also clears any in-flight ping.
        if let lastPacketAt,
           Date().timeIntervalSince(lastPacketAt) < keepAliveTimeout {
            pendingPing = nil
            return
        }

        if let pendingPing {
            if Date().timeIntervalSince(pendingPing.sentAt) > keepAliveTimeout {
                onLog?(String(format: "BLE keepalive timeout nonce=0x%08X; reconnecting", pendingPing.nonce))
                forceReconnectAfterStaleLink()
            }
            return
        }

        let nonce = UInt32.random(in: 1...UInt32.max)
        pendingPing = (nonce, Date())
        sendCommand(.ping(nonce))
    }

    private func forceReconnectAfterStaleLink() {
        stopKeepAlive()
        guard let peripheral = connectedPeripheral else {
            setState(.idle)
            if autoReconnectEnabled {
                scheduleAutoReconnect()
            }
            return
        }

        central.cancelPeripheralConnection(peripheral)
        connectedPeripheral = nil
        rxCharacteristic = nil
        setState(.idle)

        if autoReconnectEnabled {
            scheduleAutoReconnect()
        }
    }

    func sendCommand(_ command: VoiceCommand) {
        guard let peripheral = connectedPeripheral, let rxCharacteristic else {
            onLog?("RX characteristic is not ready")
            if autoReconnectEnabled,
               connectionState == .subscribed || connectionState == .connected {
                forceReconnectAfterStaleLink()
            }
            return
        }
        let type: CBCharacteristicWriteType = rxCharacteristic.properties.contains(.writeWithoutResponse)
            ? .withoutResponse
            : .withResponse
        peripheral.writeValue(command.data, for: rxCharacteristic, type: type)
    }

    private func setState(_ state: BLEConnectionState) {
        // Only emit a log line on real transitions so a packet flood through
        // setState(.subscribed) or repeated setState(.idle) doesn't spam.
        let changed = state != connectionState
        connectionState = state
        if changed {
            onLog?("State → \(state.logDescription)")
        }
        onStateChanged?(state)
    }

    private func scheduleBroadScanFallback() {
        fallbackScanWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.connectionState == .scanning, self.discovered.isEmpty else { return }
            self.isBroadScanning = true
            self.central.stopScan()
            self.central.scanForPeripherals(withServices: nil, options: [
                CBCentralManagerScanOptionAllowDuplicatesKey: false
            ])
            self.onLog?("No service-filtered result after 4s; broad scanning nearby named devices")
        }
        fallbackScanWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: workItem)
    }

    private func scheduleScanTimeout() {
        scanTimeoutWorkItem?.cancel()
        let timeout = scanTimeout
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.connectionState == .scanning else { return }
            self.onLog?("BLE scan timed out after \(Int(timeout))s")
            self.stopScan()
            // Don't give up while the app is running. The device may be off
            // for an arbitrarily long time; keep retrying on a slower cadence
            // so it picks up automatically when the user powers it back on.
            if self.autoReconnectEnabled {
                self.scheduleAutoReconnect(delay: self.scanTimeoutReconnectDelay)
            }
        }
        scanTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: workItem)
    }
}

extension BLEVoiceClient: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        onLog?("Bluetooth state: \(central.state.description)")
        if central.state == .poweredOn {
            if pendingStartScan {
                startScan()
            }
        } else if !central.state.isTransient {
            pendingStartScan = false
            setState(.failed("Bluetooth is \(central.state.description)"))
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let advertisedServices = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = peripheral.name ?? localName
        let matchesVoiceService = advertisedServices.contains(serviceUUID)
        let nameLooksRelevant = name.map { candidate in
            candidate.localizedCaseInsensitiveContains("S3Voice")
                || candidate.localizedCaseInsensitiveContains("ESP32")
                || candidate.localizedCaseInsensitiveContains("Voice")
        } ?? false

        // Always log raw discoveries during a broad scan so we can tell
        // "no advert reaches mac at all" apart from "adverts arrive but the
        // ESP32 we want isn't among them". Service-filtered scan only
        // delivers our service so it's already self-evident.
        if isBroadScanning {
            let svcs = advertisedServices.map { $0.uuidString }.joined(separator: ",")
            onLog?("adv name=\(name ?? "?") rssi=\(RSSI.intValue) svcs=[\(svcs)] match=\(matchesVoiceService) nameHit=\(nameLooksRelevant)")
        }

        guard matchesVoiceService || !isBroadScanning || nameLooksRelevant else {
            return
        }

        peripherals[peripheral.identifier] = peripheral
        discovered[peripheral.identifier] = DiscoveredVoiceDevice(
            id: peripheral.identifier,
            name: name,
            rssi: RSSI.intValue,
            discoverySource: matchesVoiceService ? "service UUID" : "broad scan"
        )
        onDevicesChanged?(discovered.values.sorted { $0.displayName < $1.displayName })

        if connectionState == .scanning, !didAutoConnect, matchesVoiceService || nameLooksRelevant {
            didAutoConnect = true
            onLog?("Auto-connecting to \(name ?? peripheral.identifier.uuidString)")
            connect(peripheral.identifier)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        cancelConnectTimeout()
        onLog?("CB didConnect \(peripheral.name ?? peripheral.identifier.uuidString); discovering services")
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: lastPeripheralIDKey)
        setState(.connected)
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        cancelConnectTimeout()
        let reason = error?.localizedDescription ?? "Failed to connect"
        onLog?("CB didFailToConnect \(peripheral.identifier.uuidString): \(reason)")
        stopKeepAlive()
        setState(.failed(reason))
        if autoReconnectEnabled {
            scheduleAutoReconnect()
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        cancelConnectTimeout()
        let wasUserInitiated = userInitiatedDisconnect
        userInitiatedDisconnect = false

        let reason = error?.localizedDescription ?? "no error"
        onLog?("CB didDisconnect \(peripheral.identifier.uuidString) (\(reason)); userInitiated=\(wasUserInitiated)")
        stopKeepAlive()
        connectedPeripheral = nil
        rxCharacteristic = nil
        setState(.idle)

        if !wasUserInitiated && autoReconnectEnabled {
            scheduleAutoReconnect()
        }
    }
}

extension BLEVoiceClient: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            onLog?("didDiscoverServices error: \(error.localizedDescription)")
            stopKeepAlive()
            setState(.failed(error.localizedDescription))
            return
        }
        let allServices = peripheral.services ?? []
        let voiceServices = allServices.filter { $0.uuid == serviceUUID }
        onLog?("didDiscoverServices: \(allServices.count) total, \(voiceServices.count) match \(VoiceUUIDs.service)")
        guard !voiceServices.isEmpty else {
            stopKeepAlive()
            setState(.failed("Voice service not found"))
            onLog?("Connected device does not expose Voice Service \(VoiceUUIDs.service)")
            if autoReconnectEnabled {
                scheduleAutoReconnect()
            }
            return
        }
        voiceServices.forEach {
            onLog?("Discovering characteristics tx=\(VoiceUUIDs.tx) rx=\(VoiceUUIDs.rx)")
            peripheral.discoverCharacteristics([txUUID, rxUUID], for: $0)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            onLog?("didDiscoverCharacteristics error: \(error.localizedDescription)")
            stopKeepAlive()
            setState(.failed(error.localizedDescription))
            return
        }
        let chars = service.characteristics ?? []
        onLog?("didDiscoverCharacteristics for \(service.uuid): \(chars.map { $0.uuid.uuidString }.joined(separator: ", "))")
        var foundTx = false
        var foundRx = false
        for characteristic in chars {
            if characteristic.uuid == txUUID {
                foundTx = true
                onLog?("Subscribing to TX \(characteristic.uuid)")
                peripheral.setNotifyValue(true, for: characteristic)
            } else if characteristic.uuid == rxUUID {
                foundRx = true
                rxCharacteristic = characteristic
                onLog?("RX characteristic ready (props=\(characteristic.properties.rawValue))")
            }
        }
        if !foundTx { onLog?("TX characteristic \(VoiceUUIDs.tx) NOT advertised by peer") }
        if !foundRx { onLog?("RX characteristic \(VoiceUUIDs.rx) NOT advertised by peer") }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            onLog?("didUpdateNotificationState error on \(characteristic.uuid): \(error.localizedDescription)")
            stopKeepAlive()
            setState(.failed(error.localizedDescription))
            return
        }
        onLog?("Notify=\(characteristic.isNotifying) on \(characteristic.uuid)")
        if characteristic.uuid == txUUID, characteristic.isNotifying {
            setState(.subscribed)
            startKeepAlive()
            sendCommand(.queryState)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            onLog?("Notify error: \(error.localizedDescription)")
            return
        }
        guard characteristic.uuid == txUUID, let data = characteristic.value else { return }
        guard let packet = VoicePacketParser.parse(data) else {
            onLog?("Could not parse \(data.count) byte packet")
            return
        }
        // Mark link as alive on every received packet, regardless of type.
        lastPacketAt = Date()
        if case .heartbeat(let heartbeat) = packet.payload,
           heartbeat.isPongResponse,
           heartbeat.fedFramesOrNonce == pendingPing?.nonce {
            pendingPing = nil
        }
        onPacket?(packet)
    }
}

private extension BLEConnectionState {
    var isFailed: Bool {
        if case .failed = self {
            return true
        }
        return false
    }

    var logDescription: String {
        switch self {
        case .idle: return "idle"
        case .scanning: return "scanning"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .subscribed: return "subscribed"
        case .failed(let m): return "failed(\(m))"
        }
    }
}

private extension CBManagerState {
    var isTransient: Bool {
        self == .unknown || self == .resetting
    }

    var description: String {
        switch self {
        case .unknown: "unknown"
        case .resetting: "resetting"
        case .unsupported: "unsupported"
        case .unauthorized: "unauthorized"
        case .poweredOff: "powered off"
        case .poweredOn: "powered on"
        @unknown default: "unknown"
        }
    }
}
