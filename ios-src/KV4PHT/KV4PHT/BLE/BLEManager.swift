/*
KV4P-HT (see http://kv4p.com)
Copyright (C) 2025 Vance Vagell

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.
*/

import CoreBluetooth
import Combine

enum BLEConnectionState {
    case disconnected
    case scanning
    case connecting
    case connected
    case error(String)
}

class BLEManager: NSObject, ObservableObject {
    @Published var discoveredDevices: [CBPeripheral] = []
    @Published var connectionState: BLEConnectionState = .disconnected
    @Published var connectedPeripheral: CBPeripheral?

    let receivedData = PassthroughSubject<Data, Never>()

    private var centralManager: CBCentralManager!
    private var rxCharacteristic: CBCharacteristic?
    private var txCharacteristic: CBCharacteristic?

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    func startScanning() {
        guard centralManager.state == .poweredOn else { return }
        discoveredDevices.removeAll()
        connectionState = .scanning
        centralManager.scanForPeripherals(
            withServices: [BLEConstants.nordicUARTServiceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    func stopScanning() {
        centralManager.stopScan()
        if case .scanning = connectionState {
            connectionState = .disconnected
        }
    }

    func connect(peripheral: CBPeripheral) {
        stopScanning()
        connectionState = .connecting
        connectedPeripheral = peripheral
        peripheral.delegate = self
        centralManager.connect(peripheral, options: nil)
    }

    func disconnect() {
        if let peripheral = connectedPeripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }
        cleanup()
    }

    func write(_ data: Data) {
        guard let peripheral = connectedPeripheral,
              let characteristic = rxCharacteristic else { return }

        let mtu = peripheral.maximumWriteValueLength(for: .withoutResponse)
        if data.count <= mtu {
            peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
        } else {
            var offset = 0
            while offset < data.count {
                let chunkSize = min(mtu, data.count - offset)
                let chunk = data.subdata(in: offset..<(offset + chunkSize))
                peripheral.writeValue(chunk, for: characteristic, type: .withoutResponse)
                offset += chunkSize
            }
        }
    }

    var isConnected: Bool {
        if case .connected = connectionState { return true }
        return false
    }

    private func cleanup() {
        rxCharacteristic = nil
        txCharacteristic = nil
        connectedPeripheral = nil
        connectionState = .disconnected
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            break
        case .unauthorized:
            connectionState = .error("Bluetooth permission denied")
        case .poweredOff:
            connectionState = .error("Bluetooth is turned off")
        case .unsupported:
            connectionState = .error("Bluetooth not supported")
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager,
                         didDiscover peripheral: CBPeripheral,
                         advertisementData: [String: Any],
                         rssi RSSI: NSNumber) {
        if !discoveredDevices.contains(where: { $0.identifier == peripheral.identifier }) {
            discoveredDevices.append(peripheral)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([BLEConstants.nordicUARTServiceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectionState = .error("Failed to connect: \(error?.localizedDescription ?? "unknown error")")
        cleanup()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        cleanup()
    }
}

// MARK: - CBPeripheralDelegate

extension BLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services where service.uuid == BLEConstants.nordicUARTServiceUUID {
            peripheral.discoverCharacteristics(
                [BLEConstants.rxCharacteristicUUID, BLEConstants.txCharacteristicUUID],
                for: service
            )
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics else { return }
        for characteristic in characteristics {
            switch characteristic.uuid {
            case BLEConstants.rxCharacteristicUUID:
                rxCharacteristic = characteristic
            case BLEConstants.txCharacteristicUUID:
                txCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            default:
                break
            }
        }
        if rxCharacteristic != nil && txCharacteristic != nil {
            connectionState = .connected
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == BLEConstants.txCharacteristicUUID,
              let data = characteristic.value else { return }
        receivedData.send(data)
    }
}
