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
import os

private let logger = Logger(subsystem: "com.kv4p.ht", category: "Protocol")

// State machine parser matching protocol.h FrameParser::processByte() exactly.
// Frame format: [0xDEADBEEF delimiter] [command: 1B] [paramLen: 2B LE] [params: 0-N bytes]
class FrameParser {
    typealias CommandHandler = (RcvCommand, Data) -> Void

    private static let delimiter: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]
    private static let delimiterLength = 4
    private static let maxParamLength = 2048

    private let onCommand: CommandHandler
    private var matchedDelimiterTokens = 0
    private var command: UInt8 = 0
    private var commandParamLen = 0
    private var paramBuffer = Data()

    init(onCommand: @escaping CommandHandler) {
        self.onCommand = onCommand
    }

    func processBytes(_ data: Data) {
        for byte in data {
            processByte(byte)
        }
    }

    private func processByte(_ b: UInt8) {
        if matchedDelimiterTokens < Self.delimiterLength {
            // Matching delimiter bytes
            if b == Self.delimiter[matchedDelimiterTokens] {
                matchedDelimiterTokens += 1
            } else {
                matchedDelimiterTokens = 0
            }
        } else if matchedDelimiterTokens == Self.delimiterLength {
            // Command byte
            command = b
            matchedDelimiterTokens += 1
        } else if matchedDelimiterTokens == Self.delimiterLength + 1 {
            // ParamLen low byte
            commandParamLen = Int(b)
            matchedDelimiterTokens += 1
        } else if matchedDelimiterTokens == Self.delimiterLength + 2 {
            // ParamLen high byte
            commandParamLen |= Int(b) << 8
            paramBuffer = Data()
            matchedDelimiterTokens += 1

            if commandParamLen == 0 {
                dispatchCommand()
                reset()
                return
            }
            if commandParamLen > Self.maxParamLength {
                logger.warning("Frame rejected: paramLen \(self.commandParamLen) exceeds max \(Self.maxParamLength)")
                reset()
                return
            }
        } else {
            // Accumulating param bytes
            paramBuffer.append(b)
            if paramBuffer.count == commandParamLen {
                dispatchCommand()
                reset()
            }
        }
    }

    private func dispatchCommand() {
        let cmd = RcvCommand(rawValue: command) ?? .unknown
        logger.debug("Parsed frame: cmd=0x\(String(format: "%02X", self.command)) (\(String(describing: cmd))) params=\(self.paramBuffer.count) bytes")
        onCommand(cmd, paramBuffer)
    }

    func reset() {
        matchedDelimiterTokens = 0
        commandParamLen = 0
        paramBuffer = Data()
    }
}
