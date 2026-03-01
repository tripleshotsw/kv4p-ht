# KV4P-HT — Claude Project Knowledge

## Project Overview

ESP32-WROOM-32 ham radio transceiver.  The ESP32 talks to a **SA818 VHF/UHF RF module** over
UART (Serial2) and to an **iOS app** over BLE (Nordic UART Service) or to a **host computer**
over USB serial (same binary protocol on both transports).

- Firmware language: **Arduino/C++ on FreeRTOS** (PlatformIO, espressif32 platform)
- Audio codec: **Opus** (via arduino-libopus)
- BLE stack: **ESP32_BleSerial** (Nordic UART Service)
- RF module driver: **arduino-dra818** (covers both SA818 VHF and SA818 UHF)

## Key Source Files

| File | Role |
|------|------|
| `kv4p_ht_esp32_wroom_32.ino` | `setup()` / `loop()`, state machine, command dispatch (`handleCommands`) |
| `protocol.h` | Frame format, `FrameParser`, all command enums & structs, `send*()` helpers |
| `transport.h` | `TransportManager` (BLE ↔ USB mux), `MultiStream` |
| `globals.h` | Mode enum, pin config, HWConfig, PROTO_MTU (2048), AUDIO_SAMPLE_RATE (48 kHz) |
| `debug.h` | `_LOGI/_LOGE/_LOGW` macros, `measureLoopFrequency()` (emits Stack HWM every 1 s) |
| `rxAudio.h` | I2S ADC → Opus encoder → transport |
| `txAudio.h` | Transport → Opus decoder → I2S DAC |
| `board.h` | Board-specific pin overrides |
| `buttons.h` | Physical PTT button handling |
| `led.h` | NeoPixel / LED state |
| `utils.h` | `Debounce`, `EVERY_N_MILLISECONDS` macro |

## Build Commands

```bash
cd microcontroller-src

# Debug build (default — keeps _LOGI/_LOGE macros active)
pio run -e esp32dev

# Release build (strips all debug logging)
pio run -e esp32dev-release

# Flash
pio run -t upload -e esp32dev

# Monitor serial output
pio device monitor --baud 115200
```

## Critical Constraints

| Constraint | Value | Why it matters |
|------------|-------|----------------|
| Loop task stack | **32 KB** (set in `platformio.ini`) | Opus needs ~10–20 KB; default 8 KB causes stack overflow |
| BLE MTU | **512 bytes** | Frames larger than MTU are fragmented by ESP32_BleSerial |
| PROTO_MTU | **2048 bytes** | Max parameter payload size |
| FreeRTOS tick | **1 ms** | Affects timing of `EVERY_N_MILLISECONDS` |
| USB Serial baud | **115200** | Both debug and protocol share this port |
| WDT timeout | **10 s** | Firmware resets if loop stalls; `esp_task_wdt_reset()` scattered through handlers |
| CONFIG handshake | **up to 20 s** | 3 outer × 3 inner retries at 2 s each for SA818 handshake |

## Protocol v2.2 Summary

**Frame format:**  `[0xDE 0xAD 0xBE 0xEF] [cmd: 1 byte] [param_len: 2 bytes LE] [params: N bytes]`

**After every received frame** the ESP32 sends `WINDOW_UPDATE` (0x09) with the byte count just consumed.

**Key handshake sequence (iOS / test harness order):**

```
host → ESP32:  STOP   (0x05, no params)
ESP32 → host:  WINDOW_UPDATE

host → ESP32:  CONFIG (0x06, bool isHigh = 0x00)
ESP32 → host:  VERSION (0x08) + WINDOW_UPDATE   ← triggers SA818 handshake (up to 20 s)

host → ESP32:  RSSI   (0x09, bool on = 0x01)
ESP32 → host:  WINDOW_UPDATE

host → ESP32:  GROUP  (0x03, 12-byte packed struct)
ESP32 → host:  WINDOW_UPDATE + periodic RX_AUDIO + SMETER_REPORT
```

**On startup** the ESP32 emits text preamble, then: DEBUG_INFO (environment/config), HELLO (0x06).

## Testing Without iOS

```bash
pip install pyserial
python scripts/test_handshake.py --port /dev/cu.usbserial-XXXX
```

Exit 0 = pass, 1 = crash detected, 2 = timeout/no response.

The script sends STOP → CONFIG → RSSI → GROUP over USB serial, parses every response frame,
reports Stack HWM from debug logs, and detects crashes via panic reset reason.

**This works because** `TransportManager` defaults to USB serial when BLE is not connected;
`FrameParser` processes bytes from either transport identically.

## State Machine

```
MODE_STOPPED  ←→  (on STOP command)
     ↓ GROUP received
MODE_RX  →  (on PTT_DOWN)  →  MODE_TX
     ↑                              ↓
     ←←←←← (on PTT_UP) ←←←←←←←←←←←
```

## Active Branch / Recent Work

Branch `ble-2026` — BLE stability fixes.  Recent commits addressed:
- Stack overflow (loop stack bumped to 32 KB)
- BLE frame fragmentation
- Blocking radio calls on BLE task
- Duplicate VERSION handling
- WINDOW_UPDATE flow control

See `memory/architecture.md` for deeper notes, `memory/protocol.md` for full byte tables.
