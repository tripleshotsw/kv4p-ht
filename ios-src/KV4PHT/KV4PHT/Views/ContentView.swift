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

struct ContentView: View {
    @EnvironmentObject var radioService: RadioService

    var body: some View {
        switch radioService.state.connectionStatus {
        case .disconnected, .scanning:
            ConnectionView()
        case .connecting, .handshaking:
            VStack(spacing: 16) {
                ProgressView()
                Text("Connecting to radio...")
                    .foregroundColor(.secondary)
            }
        case .connected:
            RadioView()
        case .error(let message):
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundColor(.red)
                Text(message)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                Button("Try Again") {
                    radioService.disconnect()
                }
            }
            .padding()
        }
    }
}
