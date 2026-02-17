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

import SwiftUI

struct DebugLogView: View {
    @EnvironmentObject var radioService: RadioService

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        List {
            if radioService.state.debugMessages.isEmpty {
                Text("No debug messages yet")
                    .foregroundColor(.secondary)
            } else {
                ForEach(radioService.state.debugMessages.reversed()) { msg in
                    HStack(alignment: .top, spacing: 8) {
                        Text(Self.timeFormatter.string(from: msg.timestamp))
                            .font(.caption2.monospaced())
                            .foregroundColor(.secondary)
                        Text(msg.level)
                            .font(.caption2.monospaced().bold())
                            .foregroundColor(colorForLevel(msg.level))
                            .frame(width: 44, alignment: .leading)
                        Text(msg.message)
                            .font(.caption.monospaced())
                    }
                }
            }
        }
        .navigationTitle("Debug Log")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Clear") {
                    radioService.state.debugMessages.removeAll()
                }
            }
        }
    }

    private func colorForLevel(_ level: String) -> Color {
        switch level {
        case "ERROR": return .red
        case "WARN": return .orange
        case "INFO": return .blue
        case "DEBUG": return .secondary
        case "TRACE": return .secondary
        default: return .primary
        }
    }
}
