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

// Commands sent from host to device (iOS -> ESP32)
// Matches RcvCommand in protocol.h (named from device's perspective)
enum SndCommand: UInt8 {
    case unknown   = 0x00
    case pttDown   = 0x01
    case pttUp     = 0x02
    case group     = 0x03
    case filters   = 0x04
    case stop      = 0x05
    case config    = 0x06
    case txAudio   = 0x07
    case hl        = 0x08
    case rssi      = 0x09
}

// Commands received from device (ESP32 -> iOS)
// Matches SndCommand in protocol.h (named from device's perspective)
enum RcvCommand: UInt8 {
    case unknown      = 0x00
    case debugInfo    = 0x01
    case debugError   = 0x02
    case debugWarn    = 0x03
    case debugDebug   = 0x04
    case debugTrace   = 0x05
    case hello        = 0x06
    case rxAudio      = 0x07
    case version      = 0x08
    case windowUpdate = 0x09
    case physPttDown  = 0x44
    case smeterReport = 0x53
    case physPttUp    = 0x55
}

enum RfModuleType: UInt32 {
    case vhf = 0  // SA818V
    case uhf = 1  // SA818U
}

enum RadioStatus: UInt8 {
    case unknown  = 0x75  // 'u'
    case notFound = 0x78  // 'x'
    case found    = 0x66  // 'f'
}

// COMMAND_HOST_GROUP parameters - 12 bytes packed, little-endian
// Matches Group struct in protocol.h
struct GroupParams {
    let bandwidth: UInt8   // 0x00 = 12.5kHz, 0x01 = 25kHz
    let freqTx: Float
    let freqRx: Float
    let ctcssTx: UInt8
    let squelch: UInt8
    let ctcssRx: UInt8

    func toData() -> Data {
        var data = Data()
        data.append(bandwidth)
        data.append(freqTx.littleEndianData)
        data.append(freqRx.littleEndianData)
        data.append(ctcssTx)
        data.append(squelch)
        data.append(ctcssRx)
        return data  // 12 bytes
    }
}

// COMMAND_VERSION response - 12 bytes packed, little-endian
// Matches Version struct in protocol.h
struct FirmwareVersion {
    let ver: UInt16
    let radioModuleStatus: RadioStatus
    let windowSize: UInt32
    let rfModuleType: RfModuleType
    let features: UInt8

    var hasHighLow: Bool { features & 0x01 != 0 }
    var hasPhysPtt: Bool { features & 0x02 != 0 }

    static func from(data: Data) -> FirmwareVersion? {
        guard data.count >= 12 else { return nil }
        let ver = data.readLEUInt16(at: 0)
        let statusByte = data[2]
        let radioModuleStatus = RadioStatus(rawValue: statusByte) ?? .unknown
        let windowSize = data.readLEUInt32(at: 3)
        let rfModuleTypeRaw = data.readLEUInt32(at: 7)
        let rfModuleType = RfModuleType(rawValue: rfModuleTypeRaw) ?? .vhf
        let features = data[11]
        return FirmwareVersion(
            ver: ver,
            radioModuleStatus: radioModuleStatus,
            windowSize: windowSize,
            rfModuleType: rfModuleType,
            features: features
        )
    }
}

struct ConfigParams {
    let isHigh: Bool

    func toData() -> Data {
        Data([isHigh ? 0x01 : 0x00])
    }
}

// CTCSS tone labels matching Android ToneHelper.VALID_TONE_STRINGS
// Index 0 = None, indices 1-38 = tone frequencies sent as ctcssTx/ctcssRx bytes
enum CTCSSTones {
    static let labels: [String] = [
        "None", "67", "71.9", "74.4", "77", "79.7", "82.5", "85.4", "88.5",
        "91.5", "94.8", "97.4", "100", "103.5", "107.2", "110.9", "114.8",
        "118.8", "123", "127.3", "131.8", "136.5", "141.3", "146.2", "151.4",
        "156.7", "162.2", "167.9", "173.8", "179.9", "186.2", "192.8", "203.5",
        "210.7", "218.1", "225.7", "233.6", "241.8", "250.3"
    ]
}

struct RSSIReport {
    let rawValue: UInt8

    // S-meter conversion matching Android's Rssi.calculateSMeter9Value
    var sMeter9: Int {
        guard rawValue > 0 else { return 1 }
        let result = 9.73 * log(0.0297 * Double(rawValue)) - 1.88
        return max(1, min(9, Int(result.rounded())))
    }
}
