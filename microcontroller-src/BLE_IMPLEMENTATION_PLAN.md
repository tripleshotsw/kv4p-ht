# BLE Support Implementation Plan for KV4P-HT ESP32 Firmware

## Overview
Add BLE peripheral support using the ESP32_BleSerial library with Nordic UART Service. The firmware will auto-switch between BLE (preferred when connected) and USB serial (fallback).

## Requirements
- **Transport**: Auto-switch - prefer BLE when connected, fall back to USB
- **BLE Profile**: Nordic UART Service via ESP32_BleSerial library
- **Device Role**: BLE peripheral (Android connects as central)
- **Scope**: Firmware only

---

## Files to Modify

### 1. NEW: `kv4p_ht_esp32_wroom_32/transport.h`
Create transport abstraction layer with:
- `TransportManager` singleton class
- `MultiStream` class that merges Serial and BleSerial inputs
- Auto-switch logic based on BLE connection state
- Unified `write()` method routing to active transport

### 2. `protocol.h` (lines 127-143, 260)
- Refactor `__sendCmdToHost()` to use `TransportManager::write()` instead of `Serial.write()`
- Change `FrameParser` from global instantiation to dynamic init after transport setup
- Add `initProtocol()` function for deferred initialization

### 3. `kv4p_ht_esp32_wroom_32.ino` (lines 79-117, 233-241)
- Add `#include "transport.h"`
- In `setup()`: Initialize `TransportManager` after Serial, call `initProtocol()`
- In `loop()`: Add `TransportManager::getInstance().loop()` call

### 4. `platformio.ini`
- Add ESP32_BleSerial library dependency:
  ```
  avinabmalla/ESP32_BleSerial@^1.0.4
  ```

---

## Implementation Steps

### Phase 1: Foundation
1. Create `transport.h` with TransportManager and MultiStream classes
2. Add ESP32_BleSerial dependency to platformio.ini
3. Compile to verify no conflicts

### Phase 2: Protocol Refactoring
4. Add forward declaration and include for transport in `protocol.h`
5. Refactor `__sendCmdToHost()` to use TransportManager
6. Convert FrameParser to dynamic initialization with `initProtocol()`
7. Test USB-only to verify no regression

### Phase 3: Main Integration
8. Update `setup()` with transport initialization sequence
9. Add `TransportManager::loop()` to main loop
10. Test complete USB communication path

### Phase 4: BLE Testing
11. Test BLE advertising (device visible as "KV4P-HT")
12. Test BLE connection and auto-switch
13. Test bidirectional command/audio transfer over BLE
14. Test fallback to USB on BLE disconnect

---

## Key Code Changes

### transport.h (new file) - Core Structure
```cpp
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
```

### protocol.h changes

**Replace lines 127-143** (`__sendCmdToHost` function):
```cpp
void __sendCmdToHost(SndCommand cmd, const uint8_t *params, size_t paramsLen) {
  if (paramsLen > PROTO_MTU) {
    paramsLen = PROTO_MTU;
  }
  TransportManager& transport = TransportManager::getInstance();
  transport.write(COMMAND_DELIMITER, DELIMITER_LENGTH);
  transport.write((uint8_t*) &cmd, 1);
  uint16_t len = paramsLen;
  transport.write((uint8_t*) &len, sizeof(len));
  if (paramsLen > 0) {
    transport.write(params, paramsLen);
  }
  transport.flush();
}
```

**Replace lines 258-264** (FrameParser instantiation):
```cpp
// Forward declaration of handleCommands function
void handleCommands(RcvCommand command, uint8_t *params, size_t param_len);

// Deferred initialization - parser created after transport setup
FrameParser* parser = nullptr;

void initProtocol() {
  parser = new FrameParser(TransportManager::getInstance().getInputStream(), &handleCommands);
}

void inline protocolLoop() {
  if (parser) {
    parser->loop();
  }
}
```

**Add include at top of protocol.h** (after line 22):
```cpp
#include "transport.h"
```

### kv4p_ht_esp32_wroom_32.ino changes

**Add include** (after line 30):
```cpp
#include "transport.h"
```

**Modify setup()** (after line 91, before watchdog init):
```cpp
  // Initialize transport manager (includes BLE)
  TransportManager::getInstance().begin();

  // Initialize protocol with transport
  initProtocol();
```

**Modify loop()** (after line 234, before debugLoop):
```cpp
  TransportManager::getInstance().loop();
```

### platformio.ini changes

**Add to lib_deps in both environments**:
```ini
lib_deps =
    https://github.com/fatpat/arduino-dra818.git#89582e3ef7bf3f31f1af149e32cec16c4b9e4cf2
    arduino-audio-tools=https://github.com/pschatzmann/arduino-audio-tools/archive/refs/tags/v1.0.1.zip
    arduino-libopus=https://github.com/pschatzmann/arduino-libopus/archive/refs/tags/a1.1.0.zip
    avinabmalla/ESP32_BleSerial@^1.0.4
```

---

## Memory Impact
- BLE stack: ~486KB Flash, ~65KB RAM
- Current usage: ~70KB RAM
- Projected total: ~143KB RAM (leaves ~377KB available)

---

## Testing Checklist
- [ ] USB communication works (regression test)
- [ ] BLE device advertises as "KV4P-HT"
- [ ] BLE connection triggers transport switch
- [ ] Commands work over BLE
- [ ] RX audio streams over BLE
- [ ] TX audio works over BLE
- [ ] BLE disconnect falls back to USB
- [ ] Reconnection works reliably

---

## Potential Challenges

### BLE Throughput
- OPUS encoding produces ~12-24kbps for narrowband voice
- BLE practical throughput: ~100-200kbps
- Should be sufficient, but monitor for buffer overruns

### MTU Negotiation
- Default BLE MTU is 20 bytes
- ESP32_BleSerial handles MTU negotiation automatically
- Android typically negotiates 512-byte MTU

### Connection Stability
- BLE can drop during RF interference
- Auto-fallback to USB provides resilience
- BLE reconnection is automatic via advertising
