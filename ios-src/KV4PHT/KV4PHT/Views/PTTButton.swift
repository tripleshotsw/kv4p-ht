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

struct PTTButton: View {
    let onPress: () -> Void
    let onRelease: () -> Void
    @State private var isPressed = false

    var body: some View {
        Text("PTT")
            .font(.system(size: 28, weight: .bold))
            .foregroundColor(.white)
            .frame(width: 120, height: 120)
            .background(isPressed ? Color.red : Color.gray)
            .clipShape(Circle())
            .shadow(color: isPressed ? .red.opacity(0.5) : .clear, radius: 10)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !isPressed {
                            isPressed = true
                            onPress()
                        }
                    }
                    .onEnded { _ in
                        isPressed = false
                        onRelease()
                    }
            )
    }
}
