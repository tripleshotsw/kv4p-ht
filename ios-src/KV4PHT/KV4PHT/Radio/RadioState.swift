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

enum ConnectionStatus: Equatable {
    case disconnected
    case scanning
    case connecting
    case handshaking
    case connected
    case error(String)
}

struct DebugMessage: Identifiable {
    let id = UUID()
    let level: String
    let message: String
    let timestamp: Date
}

class RadioState: ObservableObject {
    // Connection
    @Published var connectionStatus: ConnectionStatus = .disconnected
    @Published var firmwareVersion: FirmwareVersion?

    // Device capabilities
    @Published var rfModuleType: RfModuleType = .vhf
    @Published var hasHighLow: Bool = false
    @Published var hasPhysPtt: Bool = false

    // Radio settings
    @Published var frequency: Double = 146.520
    @Published var txFrequency: Double = 146.520
    @Published var ctcssTx: UInt8 = 0
    @Published var ctcssRx: UInt8 = 0
    @Published var squelch: UInt8 = 4
    @Published var bandwidth: UInt8 = 1  // 0x01 = 25kHz
    @Published var isHighPower: Bool = true

    // Operating state
    @Published var isPttActive: Bool = false
    @Published var isPhysPttActive: Bool = false
    @Published var rssiRaw: UInt8 = 0
    @Published var sMeter: Int = 0

    // Debug
    @Published var debugMessages: [DebugMessage] = []

    var minFrequency: Double {
        rfModuleType == .uhf ? 400.0 : 134.0
    }

    var maxFrequency: Double {
        rfModuleType == .uhf ? 480.0 : 174.0
    }
}
