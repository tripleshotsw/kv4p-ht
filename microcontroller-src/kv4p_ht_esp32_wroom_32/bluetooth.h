/*
KV4P-HT (see http://kv4p.com)
Copyright (C) 2024 Vance Vagell

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
#pragma once

#include <Arduino.h>
#include "BleSerial.h"
#include "globals.h"
#include "protocol.h"

#define BLE_DEVICE_NAME "KV4P-HT"
// Nordic Serial ids.
#define BLE_SERVICE_UUID "6e400001-b5a3-f393-e0a9-e50e24dcca9e"
#define BLE_RX_UUID     "6e400002-b5a3-f393-e0a9-e50e24dcca9e"
#define BLE_TX_UUID     "6e400003-b5a3-f393-e0a9-e50e24dcca9e"

BleSerial bleSerial;

class Bluetooth {
    public:
    static void init() {
        bleSerial.begin(BLE_DEVICE_NAME, BLE_SERVICE_UUID, BLE_RX_UUID, BLE_TX_UUID);
    }

    static void stop() {
        bleSerial.end();
    }

    static bool isConnected() {
        return bleSerial.connected();
    }

    static size_t write(const uint8_t* buffer, size_t size) {
        return bleSerial.write(buffer, size);
    }

    static size_t write(uint8_t byte) {
        return bleSerial.write(byte);
    }

    static int available() {
        return bleSerial.available();
    }

    static int read() {
        return bleSerial.read();
    }

    static size_t readBytes(uint8_t* buffer, size_t length) {
        return bleSerial.readBytes(buffer, length);
    }

    static void flush() {
        bleSerial.flush();
    }
};