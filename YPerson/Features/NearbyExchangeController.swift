import CoreBluetooth
import Foundation

final class NearbyExchangeController: NSObject, CBCentralManagerDelegate, CBPeripheralManagerDelegate {
    private static let serviceUUID = CBUUID(string: "7AC3D7F8-55B2-4A7E-95CD-4E36D0294E4A")
    private lazy var central = CBCentralManager(delegate: self, queue: .main)
    private lazy var peripheral = CBPeripheralManager(delegate: self, queue: .main)
    private var token = String(UUID().uuidString.prefix(8))
    private var resultHandler: ((String) -> Void)?
    private var stateHandler: ((AuthorizationState) -> Void)?

    func start(onState: @escaping (AuthorizationState) -> Void, onToken: @escaping (String) -> Void) {
        stateHandler = onState
        resultHandler = onToken
        _ = central
        _ = peripheral
        updateOperations()
    }

    func stop() {
        central.stopScan()
        peripheral.stopAdvertising()
        resultHandler = nil
        stateHandler = nil
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) { updateOperations() }
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) { updateOperations() }

    private func updateOperations() {
        guard central.state != .unknown, peripheral.state != .unknown else { return }
        guard central.state == .poweredOn, peripheral.state == .poweredOn else {
            let denied = CBManager.authorization == .denied
            stateHandler?(denied ? .denied : .unavailable("Bluetooth выключен или недоступен"))
            return
        }
        stateHandler?(.authorized("Поиск активен"))
        token = String(UUID().uuidString.prefix(8))
        peripheral.stopAdvertising()
        peripheral.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID],
            CBAdvertisementDataServiceDataKey: [Self.serviceUUID: Data(token.utf8)]
        ])
        central.stopScan()
        central.scanForPeripherals(withServices: [Self.serviceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data],
              let data = serviceData[Self.serviceUUID],
              let peerToken = String(data: data, encoding: .utf8), peerToken != token else { return }
        resultHandler?(peerToken)
        stop()
    }
}
