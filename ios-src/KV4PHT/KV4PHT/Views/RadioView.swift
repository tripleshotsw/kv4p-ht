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

struct RadioView: View {
    @EnvironmentObject var radioService: RadioService
    @State private var frequencyText: String = ""

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                // Frequency display
                VStack(spacing: 4) {
                    Text("RX Frequency")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    HStack {
                        TextField("Frequency", text: $frequencyText)
                            .font(.system(size: 36, weight: .bold, design: .monospaced))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.center)
                        Text("MHz")
                            .font(.title2)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal)

                    Button("Tune") {
                        if let freq = Double(frequencyText) {
                            radioService.state.frequency = freq
                            radioService.state.txFrequency = freq
                            radioService.tune()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(12)
                .padding(.horizontal)

                // S-Meter
                SMeterView(value: radioService.state.sMeter)
                    .padding(.horizontal)

                // Settings row
                HStack(spacing: 16) {
                    // Squelch
                    VStack {
                        Text("Squelch")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Picker("Squelch", selection: Binding(
                            get: { radioService.state.squelch },
                            set: { radioService.state.squelch = $0 }
                        )) {
                            ForEach(0..<9) { level in
                                Text("\(level)").tag(UInt8(level))
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    // Bandwidth
                    VStack {
                        Text("Bandwidth")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Picker("BW", selection: Binding(
                            get: { radioService.state.bandwidth },
                            set: { radioService.state.bandwidth = $0 }
                        )) {
                            Text("25kHz").tag(UInt8(1))
                            Text("12.5kHz").tag(UInt8(0))
                        }
                        .pickerStyle(.menu)
                    }

                    // Power
                    if radioService.state.hasHighLow {
                        VStack {
                            Text("Power")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Button(radioService.state.isHighPower ? "High" : "Low") {
                                radioService.setHighPower(!radioService.state.isHighPower)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
                .padding(.horizontal)

                Spacer()

                // PTT indicator for physical button
                if radioService.state.isPhysPttActive {
                    Text("Physical PTT Active")
                        .font(.caption)
                        .padding(8)
                        .background(Color.red.opacity(0.2))
                        .cornerRadius(8)
                }

                // PTT Button
                PTTButton(
                    onPress: { radioService.pttDown() },
                    onRelease: { radioService.pttUp() }
                )
                .padding(.bottom, 30)
            }
            .navigationTitle("KV4P HT")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Disconnect") {
                        radioService.disconnect()
                    }
                }
            }
            .onAppear {
                frequencyText = String(format: "%.4f", radioService.state.frequency)
            }
        }
    }
}
