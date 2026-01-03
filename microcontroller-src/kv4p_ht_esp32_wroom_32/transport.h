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
#pragma once

#include <Arduino.h>
#include <BleSerial.h>
#include "globals.h"

#define BLE_DEVICE_NAME "KV4P-HT"

enum TransportType {
  TRANSPORT_USB_SERIAL = 0,
  TRANSPORT_BLE = 1
};

/**
 * MultiStream - Wraps multiple input streams, returns data from first available
 * This allows FrameParser to receive from either USB or BLE
 */
class MultiStream : public Stream {
public:
  MultiStream(Stream& primary, Stream& secondary)
    : _primary(primary), _secondary(secondary), _preferSecondary(false) {}

  void setPreferSecondary(bool prefer) { _preferSecondary = prefer; }

  int available() override {
    if (_preferSecondary && _secondary.available()) {
      return _secondary.available();
    }
    if (_primary.available()) {
      return _primary.available();
    }
    return _secondary.available();
  }

  int read() override {
    if (_preferSecondary && _secondary.available()) {
      return _secondary.read();
    }
    if (_primary.available()) {
      return _primary.read();
    }
    if (_secondary.available()) {
      return _secondary.read();
    }
    return -1;
  }

  int peek() override {
    if (_preferSecondary && _secondary.available()) {
      return _secondary.peek();
    }
    if (_primary.available()) {
      return _primary.peek();
    }
    if (_secondary.available()) {
      return _secondary.peek();
    }
    return -1;
  }

  size_t write(uint8_t b) override { return 0; }  // Not used for input
  void flush() override {}

private:
  Stream& _primary;
  Stream& _secondary;
  bool _preferSecondary;
};

class TransportManager {
public:
  static TransportManager& getInstance() {
    static TransportManager instance;
    return instance;
  }

  void begin() {
    _bleSerial.begin(BLE_DEVICE_NAME);
    _multiStream = new MultiStream(Serial, _bleSerial);
    _initialized = true;
  }

  void loop() {
    bool currentBleState = _bleSerial.connected();
    if (currentBleState != _bleConnected) {
      _bleConnected = currentBleState;
      if (_bleConnected) {
        switchTransport(TRANSPORT_BLE);
      } else {
        switchTransport(TRANSPORT_USB_SERIAL);
      }
    }
  }

  Stream& getInputStream() {
    return *_multiStream;
  }

  size_t write(const uint8_t* buffer, size_t size) {
    if (_activeTransport == TRANSPORT_BLE && _bleConnected) {
      return _bleSerial.write(buffer, size);
    }
    return Serial.write(buffer, size);
  }

  size_t write(uint8_t byte) {
    if (_activeTransport == TRANSPORT_BLE && _bleConnected) {
      return _bleSerial.write(byte);
    }
    return Serial.write(byte);
  }

  void flush() {
    if (_activeTransport == TRANSPORT_BLE && _bleConnected) {
      _bleSerial.flush();
    } else {
      Serial.flush();
    }
  }

  bool isBleConnected() { return _bleConnected; }
  TransportType getActiveTransport() { return _activeTransport; }

private:
  TransportManager() = default;

  BleSerial _bleSerial;
  MultiStream* _multiStream = nullptr;
  volatile bool _bleConnected = false;
  volatile bool _initialized = false;
  TransportType _activeTransport = TRANSPORT_USB_SERIAL;

  void switchTransport(TransportType newTransport) {
    _activeTransport = newTransport;
    if (_multiStream) {
      _multiStream->setPreferSecondary(newTransport == TRANSPORT_BLE);
    }
  }
};

inline TransportManager& getTransport() {
  return TransportManager::getInstance();
}
