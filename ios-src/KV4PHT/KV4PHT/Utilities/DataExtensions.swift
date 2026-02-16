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

extension Data {
    func readLEUInt16(at offset: Int) -> UInt16 {
        let bytes = self.subdata(in: offset..<(offset + 2))
        return bytes.withUnsafeBytes { $0.load(as: UInt16.self).littleEndian }
    }

    func readLEUInt32(at offset: Int) -> UInt32 {
        let bytes = self.subdata(in: offset..<(offset + 4))
        return bytes.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
    }

    func readLEFloat(at offset: Int) -> Float {
        let bits = readLEUInt32(at: offset)
        return Float(bitPattern: bits)
    }
}

extension UInt16 {
    var littleEndianData: Data {
        var value = self.littleEndian
        return Data(bytes: &value, count: MemoryLayout<UInt16>.size)
    }
}

extension Float {
    var littleEndianData: Data {
        var bits = self.bitPattern.littleEndian
        return Data(bytes: &bits, count: MemoryLayout<UInt32>.size)
    }
}
