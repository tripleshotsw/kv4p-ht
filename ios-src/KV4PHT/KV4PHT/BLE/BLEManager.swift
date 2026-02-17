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
import os

private let logger = Logger(subsystem: "com.kv4p.ht", category: "BLE")

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
    private var lastConnectedIdentifier: UUID?
    private var autoReconnect = false

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    func startScanning() {
        guard centralManager.state == .poweredOn else {
            logger.warning("Cannot scan: Bluetooth not powered on (state: \(String(describing: self.centralManager.state.rawValue)))")
            return
        }
        discoveredDevices.removeAll()
        connectionState = .scanning
        logger.info("Started scanning for KV4P-HT devices")
        centralManager.scanForPeripherals(
            withServices: [BLEConstants.nordicUARTServiceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    func stopScanning() {
        centralManager.stopScan()
        logger.info("Stopped scanning")
        if case .scanning = connectionState {
            connectionState = .disconnected
        }
    }

    func connect(peripheral: CBPeripheral) {
        stopScanning()
        connectionState = .connecting
        connectedPeripheral = peripheral
        lastConnectedIdentifier = peripheral.identifier
        autoReconnect = true
        peripheral.delegate = self
        logger.info("Connecting to \(peripheral.name ?? "unknown", privacy: .public) (\(peripheral.identifier.uuidString, privacy: .public))")
        centralManager.connect(peripheral, options: nil)
    }

    func disconnect() {
        logger.info("Disconnecting (auto-reconnect disabled)")
        autoReconnect = false
        lastConnectedIdentifier = nil
        if let peripheral = connectedPeripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }
        cleanup()
    }

    func write(_ data: Data) {
        guard let peripheral = connectedPeripheral,
              let characteristic = rxCharacteristic else {
            logger.error("Write failed: no connected peripheral or RX characteristic")
            return
        }

        // Use the write type supported by the characteristic
        let writeType: CBCharacteristicWriteType =
            characteristic.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        let mtu = peripheral.maximumWriteValueLength(for: writeType)
        if data.count <= mtu {
            peripheral.writeValue(data, for: characteristic, type: writeType)
        } else {
            logger.debug("Chunking \(data.count) byte write (MTU: \(mtu), type: \(writeType == .withResponse ? "withResponse" : "withoutResponse"))")
            var offset = 0
            while offset < data.count {
                let chunkSize = min(mtu, data.count - offset)
                let chunk = data.subdata(in: offset..<(offset + chunkSize))
                peripheral.writeValue(chunk, for: characteristic, type: writeType)
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
        logger.info("Bluetooth state changed: \(String(describing: central.state.rawValue))")
        switch central.state {
        case .poweredOn:
            logger.info("Bluetooth powered on")
        case .unauthorized:
            logger.error("Bluetooth permission denied")
            connectionState = .error("Bluetooth permission denied")
        case .poweredOff:
            logger.warning("Bluetooth is turned off")
            connectionState = .error("Bluetooth is turned off")
        case .unsupported:
            logger.error("Bluetooth not supported on this device")
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
            logger.info("Discovered device: \(peripheral.name ?? "unknown", privacy: .public) RSSI: \(RSSI.intValue)")
            discoveredDevices.append(peripheral)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        logger.info("Connected to \(peripheral.name ?? "unknown", privacy: .public), discovering services...")
        peripheral.discoverServices([BLEConstants.nordicUARTServiceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        logger.error("Failed to connect: \(error?.localizedDescription ?? "unknown error", privacy: .public)")
        connectionState = .error("Failed to connect: \(error?.localizedDescription ?? "unknown error")")
        cleanup()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if let error = error {
            logger.warning("Disconnected with error: \(error.localizedDescription, privacy: .public)")
        } else {
            logger.info("Disconnected cleanly")
        }
        let shouldReconnect = autoReconnect
        let identifier = lastConnectedIdentifier
        cleanup()

        if shouldReconnect, let identifier = identifier {
            logger.info("Auto-reconnecting to \(identifier.uuidString, privacy: .public)...")
            connectionState = .connecting
            let peripherals = centralManager.retrievePeripherals(withIdentifiers: [identifier])
            if let peripheral = peripherals.first {
                connectedPeripheral = peripheral
                lastConnectedIdentifier = identifier
                autoReconnect = true
                peripheral.delegate = self
                centralManager.connect(peripheral, options: nil)
            } else {
                logger.warning("Auto-reconnect: peripheral not found, starting scan")
                autoReconnect = true
                lastConnectedIdentifier = identifier
                startScanning()
            }
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            logger.error("Service discovery failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard let services = peripheral.services else { return }
        logger.info("Discovered \(services.count) service(s), looking for Nordic UART...")
        for service in services where service.uuid == BLEConstants.nordicUARTServiceUUID {
            logger.info("Found Nordic UART service, discovering characteristics...")
            peripheral.discoverCharacteristics(
                [BLEConstants.rxCharacteristicUUID, BLEConstants.txCharacteristicUUID],
                for: service
            )
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            logger.error("Characteristic discovery failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard let characteristics = service.characteristics else { return }
        for characteristic in characteristics {
            switch characteristic.uuid {
            case BLEConstants.rxCharacteristicUUID:
                logger.info("Found RX characteristic (write to device), properties: 0x\(String(characteristic.properties.rawValue, radix: 16))")
                rxCharacteristic = characteristic
            case BLEConstants.txCharacteristicUUID:
                logger.info("Found TX characteristic (notify from device), properties: 0x\(String(characteristic.properties.rawValue, radix: 16)), subscribing...")
                txCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            default:
                break
            }
        }
        if rxCharacteristic != nil && txCharacteristic != nil {
            let mtu = peripheral.maximumWriteValueLength(for: .withoutResponse)
            logger.info("BLE ready - both characteristics found, MTU: \(mtu)")
            connectionState = .connected
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            logger.error("Characteristic update error: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard characteristic.uuid == BLEConstants.txCharacteristicUUID,
              let data = characteristic.value else { return }
        logger.debug("Received \(data.count) bytes from device")
        receivedData.send(data)
    }
}
