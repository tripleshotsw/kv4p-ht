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

struct SMeterView: View {
    let value: Int  // 1-9

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("S-Meter")
                .font(.caption)
                .foregroundColor(.secondary)
            HStack(spacing: 2) {
                ForEach(1...9, id: \.self) { level in
                    Rectangle()
                        .fill(barColor(for: level))
                        .frame(height: 20)
                        .opacity(level <= value ? 1.0 : 0.2)
                }
            }
            .frame(height: 20)
            HStack {
                Text("S1")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                Text("S9")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func barColor(for level: Int) -> Color {
        if level <= 3 { return .green }
        if level <= 6 { return .yellow }
        return .red
    }
}
