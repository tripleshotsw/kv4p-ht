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

// Builds outgoing command frames matching the protocol in protocol.h
// Frame format: [delimiter: 4B] [command: 1B] [paramLen: 2B LE] [params: 0-2048B]
enum FrameBuilder {
    static let delimiter: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]

    static func buildFrame(command: SndCommand, params: Data? = nil) -> Data {
        var frame = Data(delimiter)
        frame.append(command.rawValue)
        let paramLen = UInt16(params?.count ?? 0)
        frame.append(paramLen.littleEndianData)
        if let params = params {
            frame.append(params)
        }
        return frame
    }

    static func pttDown() -> Data {
        buildFrame(command: .pttDown)
    }

    static func pttUp() -> Data {
        buildFrame(command: .pttUp)
    }

    static func stop() -> Data {
        buildFrame(command: .stop)
    }

    static func config(isHigh: Bool) -> Data {
        buildFrame(command: .config, params: ConfigParams(isHigh: isHigh).toData())
    }

    static func group(_ params: GroupParams) -> Data {
        buildFrame(command: .group, params: params.toData())
    }

    static func setRSSI(on: Bool) -> Data {
        buildFrame(command: .rssi, params: Data([on ? 0x01 : 0x00]))
    }

    static func setHighPower(_ isHigh: Bool) -> Data {
        buildFrame(command: .hl, params: Data([isHigh ? 0x01 : 0x00]))
    }

    static func setFilters(pre: Bool, high: Bool, low: Bool) -> Data {
        var flags: UInt8 = 0
        if pre  { flags |= 0x01 }
        if high { flags |= 0x02 }
        if low  { flags |= 0x04 }
        return buildFrame(command: .filters, params: Data([flags]))
    }
}
