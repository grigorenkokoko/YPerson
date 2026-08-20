import CoreBluetooth
import Foundation

final class NearbyExchangeController: NSObject, CBCentralManagerDelegate, CBPeripheralManagerDelegate {
    private static let serviceUUID = CBUUID(string: "7AC3D7F8-55B2-4A7E-95CD-4E36D0294E4A")
    private var central: CBCentralManager?
    private var peripheral: CBPeripheralManager?
    private var token: String?
    private var resultHandler: ((String) -> Void)?
    private var stateHandler: ((AuthorizationState) -> Void)?
    private var isActive = false

    func start(exchangeToken: String, onState: @escaping (AuthorizationState) -> Void, onToken: @escaping (String) -> Void) {
        stop()
        token = exchangeToken
        stateHandler = onState
        resultHandler = onToken
        central = CBCentralManager(delegate: self, queue: .main)
        peripheral = CBPeripheralManager(delegate: self, queue: .main)
        updateOperations()
    }

    func stop() {
        central?.stopScan()
        peripheral?.stopAdvertising()
        central = nil
        peripheral = nil
        token = nil
        isActive = false
        resultHandler = nil
        stateHandler = nil
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) { updateOperations() }
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) { updateOperations() }

    func peripheralManager(_ peripheral: CBPeripheralManager, didStartAdvertising error: Error?) {
        if let error {
            finish(with: .unavailable("Не удалось начать Bluetooth-поиск: \(error.localizedDescription)"))
        }
    }

    private func updateOperations() {
        guard let central, let peripheral, let token else { return }
        guard central.state != .unknown, peripheral.state != .unknown else { return }
        guard central.state == .poweredOn, peripheral.state == .poweredOn else {
            let denied = CBManager.authorization == .denied
            finish(with: denied ? .denied : .unavailable("Bluetooth выключен или недоступен"))
            return
        }
        guard !isActive else { return }
        isActive = true
        stateHandler?(.authorized("Поиск активен"))
        peripheral.stopAdvertising()
        peripheral.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID],
            CBAdvertisementDataManufacturerDataKey: Data(token.utf8)
        ])
        central.stopScan()
        central.scanForPeripherals(withServices: [Self.serviceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
              let peerToken = String(data: data, encoding: .utf8),
              !peerToken.isEmpty,
              peerToken != token else { return }
        let handler = resultHandler
        stop()
        handler?(peerToken)
    }

    private func finish(with state: AuthorizationState) {
        let handler = stateHandler
        stop()
        handler?(state)
    }

    deinit { stop() }
}
