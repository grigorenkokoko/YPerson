import CoreBluetooth
import Foundation

final class NearbyExchangeController: NSObject, CBCentralManagerDelegate, CBPeripheralManagerDelegate, CBPeripheralDelegate {
    private static let serviceUUID = CBUUID(string: "7AC3D7F8-55B2-4A7E-95CD-4E36D0294E4A")
    private static let tokenCharacteristicUUID = CBUUID(string: "DC1B1B94-8A7B-4B99-9367-82B4E616D8A5")

    private var central: CBCentralManager?
    private var peripheralManager: CBPeripheralManager?
    private var connectedPeripheral: CBPeripheral?
    private var token: String?
    private var resultHandler: ((String) -> Void)?
    private var stateHandler: ((AuthorizationState) -> Void)?
    private var isActive = false
    private var handshake = NearbyExchangeHandshake()

    func start(exchangeToken: String, onState: @escaping (AuthorizationState) -> Void, onToken: @escaping (String) -> Void) {
        stop()
        handshake = NearbyExchangeHandshake()
        token = exchangeToken
        stateHandler = onState
        resultHandler = onToken
        central = CBCentralManager(delegate: self, queue: .main)
        peripheralManager = CBPeripheralManager(delegate: self, queue: .main)
        updateOperations()
    }

    func stop() {
        central?.stopScan()
        if let connectedPeripheral { central?.cancelPeripheralConnection(connectedPeripheral) }
        peripheralManager?.stopAdvertising()
        peripheralManager?.removeAllServices()
        connectedPeripheral?.delegate = nil
        connectedPeripheral = nil
        central = nil
        peripheralManager = nil
        token = nil
        isActive = false
        handshake = NearbyExchangeHandshake()
        resultHandler = nil
        stateHandler = nil
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) { updateOperations() }
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) { updateOperations() }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard error == nil else {
            finish(with: .unavailable("Не удалось подготовить Bluetooth-обмен"))
            return
        }
        peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID]])
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didStartAdvertising error: Error?) {
        if let error {
            finish(with: .unavailable("Не удалось начать Bluetooth-поиск: \(error.localizedDescription)"))
        }
    }

    private func updateOperations() {
        guard let central, let peripheralManager, token != nil else { return }
        guard central.state != .unknown, peripheralManager.state != .unknown else { return }
        guard central.state == .poweredOn, peripheralManager.state == .poweredOn else {
            let denied = CBManager.authorization == .denied
            finish(with: denied ? .denied : .unavailable("Bluetooth выключен или недоступен"))
            return
        }
        guard !isActive else { return }
        isActive = true
        stateHandler?(.authorized("Поиск активен"))

        let characteristic = CBMutableCharacteristic(
            type: Self.tokenCharacteristicUUID,
            properties: [.read],
            value: nil,
            permissions: [.readable]
        )
        let service = CBMutableService(type: Self.serviceUUID, primary: true)
        service.characteristics = [characteristic]
        peripheralManager.removeAllServices()
        peripheralManager.add(service)

        central.stopScan()
        central.scanForPeripherals(
            withServices: [Self.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard connectedPeripheral == nil else { return }
        connectedPeripheral = peripheral
        peripheral.delegate = self
        central.stopScan()
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        finish(with: .unavailable(error?.localizedDescription ?? "Не удалось подключиться к человеку рядом"))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard resultHandler != nil else { return }
        finish(with: .unavailable(error?.localizedDescription ?? "Bluetooth-соединение прервано"))
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil,
              let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            finish(with: .unavailable("Сервис обмена не найден"))
            return
        }
        peripheral.discoverCharacteristics([Self.tokenCharacteristicUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil,
              let characteristic = service.characteristics?.first(where: { $0.uuid == Self.tokenCharacteristicUUID }) else {
            finish(with: .unavailable("Токен обмена не найден"))
            return
        }
        peripheral.readValue(for: characteristic)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil,
              characteristic.uuid == Self.tokenCharacteristicUUID,
              let data = characteristic.value,
              let peerToken = String(data: data, encoding: .utf8),
              !peerToken.isEmpty,
              peerToken != token else {
            finish(with: .unavailable("Получен некорректный токен обмена"))
            return
        }
        if let completedPeerToken = handshake.recordPeerToken(peerToken) {
            completeExchange(with: completedPeerToken)
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        guard request.characteristic.uuid == Self.tokenCharacteristicUUID,
              let token else {
            peripheral.respond(to: request, withResult: .requestNotSupported)
            return
        }
        let data = Data(token.utf8)
        guard request.offset <= data.count else {
            peripheral.respond(to: request, withResult: .invalidOffset)
            return
        }
        request.value = data.subdata(in: request.offset..<data.count)
        peripheral.respond(to: request, withResult: .success)
        guard let completedPeerToken = handshake.recordOwnTokenServed() else { return }
        DispatchQueue.main.async { [weak self] in
            self?.completeExchange(with: completedPeerToken)
        }
    }

    private func completeExchange(with peerToken: String) {
        guard let handler = resultHandler else { return }
        stop()
        handler(peerToken)
    }

    private func finish(with state: AuthorizationState) {
        let handler = stateHandler
        stop()
        handler?(state)
    }

    deinit { stop() }
}
