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

struct ConnectionView: View {
    @EnvironmentObject var radioService: RadioService

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                if radioService.bleManager.discoveredDevices.isEmpty {
                    Spacer()
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 60))
                        .foregroundColor(.secondary)
                    Text("No devices found")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Text("Make sure your KV4P-HT is powered on")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                } else {
                    List(radioService.bleManager.discoveredDevices, id: \.identifier) { peripheral in
                        Button {
                            radioService.connect(to: peripheral)
                        } label: {
                            HStack {
                                Image(systemName: "radio")
                                Text(peripheral.name ?? "Unknown Device")
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }

                if case .scanning = radioService.state.connectionStatus {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Scanning...")
                            .foregroundColor(.secondary)
                    }
                }

                Button {
                    if case .scanning = radioService.state.connectionStatus {
                        radioService.stopScanning()
                    } else {
                        radioService.startScanning()
                    }
                } label: {
                    Group {
                        if case .scanning = radioService.state.connectionStatus {
                            Text("Stop Scanning")
                        } else {
                            Text("Scan for Devices")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
                .padding(.horizontal)
                .padding(.bottom)
            }
            .navigationTitle("KV4P HT")
        }
    }
}
