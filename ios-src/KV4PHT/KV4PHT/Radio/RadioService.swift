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

import Foundation
import Combine

// Orchestrates BLE communication, protocol handshake, and command dispatch.
// Mirrors the Android RadioAudioService + ProtocolHandshake pattern.
class RadioService: ObservableObject {
    let state = RadioState()
    let bleManager = BLEManager()
    private var frameParser: FrameParser!
    private var cancellables = Set<AnyCancellable>()

    // Flow control
    private var flowControlWindow: Int = 0

    // Handshake state
    private var handshakeTimer: DispatchWorkItem?
    private var versionTimer: DispatchWorkItem?

    init() {
        frameParser = FrameParser { [weak self] cmd, data in
            self?.handleCommand(cmd, data)
        }

        bleManager.receivedData
            .sink { [weak self] data in
                self?.frameParser.processBytes(data)
            }
            .store(in: &cancellables)

        bleManager.$connectionState
            .sink { [weak self] bleState in
                self?.handleBLEStateChange(bleState)
            }
            .store(in: &cancellables)
    }

    // MARK: - Public API

    func startScanning() {
        state.connectionStatus = .scanning
        bleManager.startScanning()
    }

    func stopScanning() {
        bleManager.stopScanning()
        state.connectionStatus = .disconnected
    }

    func connect(to peripheral: CBPeripheral) {
        state.connectionStatus = .connecting
        bleManager.connect(peripheral: peripheral)
    }

    func disconnect() {
        handshakeTimer?.cancel()
        versionTimer?.cancel()
        bleManager.disconnect()
        state.connectionStatus = .disconnected
    }

    func pttDown() {
        send(FrameBuilder.pttDown())
        state.isPttActive = true
    }

    func pttUp() {
        send(FrameBuilder.pttUp())
        state.isPttActive = false
    }

    func tune() {
        let params = GroupParams(
            bandwidth: state.bandwidth,
            freqTx: Float(state.txFrequency),
            freqRx: Float(state.frequency),
            ctcssTx: state.ctcssTx,
            squelch: state.squelch,
            ctcssRx: state.ctcssRx
        )
        send(FrameBuilder.group(params))
    }

    func setRSSIEnabled(_ on: Bool) {
        send(FrameBuilder.setRSSI(on: on))
    }

    func setHighPower(_ isHigh: Bool) {
        send(FrameBuilder.setHighPower(isHigh))
        state.isHighPower = isHigh
    }

    // MARK: - BLE State Handling

    private func handleBLEStateChange(_ bleState: BLEConnectionState) {
        switch bleState {
        case .connected:
            startHandshake()
        case .disconnected:
            DispatchQueue.main.async {
                self.state.connectionStatus = .disconnected
            }
        case .error(let msg):
            DispatchQueue.main.async {
                self.state.connectionStatus = .error(msg)
            }
        default:
            break
        }
    }

    // MARK: - Handshake (matches ProtocolHandshake.java flow)

    private func startHandshake() {
        DispatchQueue.main.async {
            self.state.connectionStatus = .handshaking
        }
        // Wait up to 1 second for HELLO from device
        let timeout = DispatchWorkItem { [weak self] in
            // If we haven't received HELLO, try sending config anyway
            self?.sendConfigAndWaitForVersion()
        }
        handshakeTimer = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: timeout)
    }

    private func onHelloReceived() {
        handshakeTimer?.cancel()
        sendConfigAndWaitForVersion()
    }

    private func sendConfigAndWaitForVersion() {
        send(FrameBuilder.stop())
        send(FrameBuilder.config(isHigh: state.isHighPower))

        // Wait up to 60 seconds for VERSION response
        let timeout = DispatchWorkItem { [weak self] in
            DispatchQueue.main.async {
                self?.state.connectionStatus = .error("Timeout waiting for firmware version")
            }
        }
        versionTimer = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 60.0, execute: timeout)
    }

    private func onVersionReceived(_ data: Data) {
        versionTimer?.cancel()
        guard let version = FirmwareVersion.from(data: data) else {
            DispatchQueue.main.async {
                self.state.connectionStatus = .error("Invalid firmware version response")
            }
            return
        }

        DispatchQueue.main.async {
            self.state.firmwareVersion = version
            self.state.rfModuleType = version.rfModuleType
            self.state.hasHighLow = version.hasHighLow
            self.state.hasPhysPtt = version.hasPhysPtt
            self.flowControlWindow = Int(version.windowSize)

            if version.radioModuleStatus == .notFound {
                self.state.connectionStatus = .error("Radio module not found")
                return
            }

            self.state.connectionStatus = .connected
            self.setRSSIEnabled(true)
            self.tune()
        }
    }

    // MARK: - Command Dispatch

    private func handleCommand(_ cmd: RcvCommand, _ data: Data) {
        DispatchQueue.main.async { [self] in
            switch cmd {
            case .hello:
                onHelloReceived()
            case .version:
                onVersionReceived(data)
            case .smeterReport:
                guard data.count >= 1 else { return }
                let report = RSSIReport(rawValue: data[0])
                state.rssiRaw = report.rawValue
                state.sMeter = report.sMeter9
            case .physPttDown:
                state.isPhysPttActive = true
            case .physPttUp:
                state.isPhysPttActive = false
            case .windowUpdate:
                guard data.count >= 4 else { return }
                flowControlWindow += Int(data.readLEUInt32(at: 0))
            case .debugInfo, .debugError, .debugWarn, .debugDebug, .debugTrace:
                let level: String
                switch cmd {
                case .debugInfo: level = "INFO"
                case .debugError: level = "ERROR"
                case .debugWarn: level = "WARN"
                case .debugDebug: level = "DEBUG"
                case .debugTrace: level = "TRACE"
                default: level = "UNKNOWN"
                }
                let message = String(data: data, encoding: .utf8) ?? "<binary>"
                state.debugMessages.append(DebugMessage(level: level, message: message, timestamp: Date()))
            case .rxAudio:
                break  // Deferred to future audio phase
            default:
                break
            }
        }
    }

    // MARK: - Send with flow control

    private func send(_ data: Data) {
        bleManager.write(data)
    }
}

import CoreBluetooth
