#!/usr/bin/env python3
"""
KV4P-HT Serial Protocol Test Harness

Replaces iOS for basic protocol and crash testing.  Sends the standard
iOS handshake sequence (STOP → CONFIG → RSSI-enable → GROUP) over USB
serial and checks whether the ESP32 stays alive.

Exit codes:
  0 = pass  (firmware alive ≥5 s after GROUP)
  1 = crash (silence or Reset Reason: Panic/WDT after GROUP)
  2 = timeout / no response from firmware

Usage:
  python scripts/test_handshake.py --port /dev/cu.usbserial-XXXX [--timeout 10]
"""

import argparse
import struct
import sys
import time

try:
    import serial
except ImportError:
    print("ERROR: pyserial not found.  Run: pip install pyserial", file=sys.stderr)
    sys.exit(2)

# ── Protocol constants ──────────────────────────────────────────────────────

DELIMITER = bytes([0xDE, 0xAD, 0xBE, 0xEF])

# Outgoing command codes (host → ESP32)
CMD_OUT_PTT_DOWN = 0x01
CMD_OUT_PTT_UP   = 0x02
CMD_OUT_GROUP    = 0x03
CMD_OUT_FILTERS  = 0x04
CMD_OUT_STOP     = 0x05
CMD_OUT_CONFIG   = 0x06
CMD_OUT_TX_AUDIO = 0x07
CMD_OUT_HL       = 0x08
CMD_OUT_RSSI     = 0x09

# Incoming command codes (ESP32 → host)
CMD_IN_SMETER        = 0x53
CMD_IN_PHYS_PTT_DOWN = 0x44
CMD_IN_PHYS_PTT_UP   = 0x55
CMD_IN_DEBUG_INFO    = 0x01
CMD_IN_DEBUG_ERROR   = 0x02
CMD_IN_DEBUG_WARN    = 0x03
CMD_IN_DEBUG_DEBUG   = 0x04
CMD_IN_DEBUG_TRACE   = 0x05
CMD_IN_HELLO         = 0x06
CMD_IN_RX_AUDIO      = 0x07
CMD_IN_VERSION       = 0x08
CMD_IN_WINDOW_UPDATE = 0x09

CMD_IN_NAMES = {
    CMD_IN_SMETER:        "SMETER_REPORT",
    CMD_IN_PHYS_PTT_DOWN: "PHYS_PTT_DOWN",
    CMD_IN_PHYS_PTT_UP:   "PHYS_PTT_UP",
    CMD_IN_DEBUG_INFO:    "DEBUG_INFO",
    CMD_IN_DEBUG_ERROR:   "DEBUG_ERROR",
    CMD_IN_DEBUG_WARN:    "DEBUG_WARN",
    CMD_IN_DEBUG_DEBUG:   "DEBUG_DEBUG",
    CMD_IN_DEBUG_TRACE:   "DEBUG_TRACE",
    CMD_IN_HELLO:         "HELLO",
    CMD_IN_RX_AUDIO:      "RX_AUDIO",
    CMD_IN_VERSION:       "VERSION",
    CMD_IN_WINDOW_UPDATE: "WINDOW_UPDATE",
}

# ── Frame builder ───────────────────────────────────────────────────────────

def make_frame(cmd: int, params: bytes = b"") -> bytes:
    """Build a protocol frame: DELIMITER + cmd(1) + len(2 LE) + params."""
    return DELIMITER + bytes([cmd]) + len(params).to_bytes(2, "little") + params

FRAME_STOP    = make_frame(CMD_OUT_STOP)
FRAME_CONFIG  = make_frame(CMD_OUT_CONFIG, bytes([0x00]))           # isHigh=false
FRAME_RSSI_ON = make_frame(CMD_OUT_RSSI,   bytes([0x01]))           # on=true
# Group{bw=0, freq_tx=146.52, freq_rx=146.52, ctcss_tx=0, squelch=1, ctcss_rx=0}
# struct layout (gnu::packed): uint8_t bw, float freq_tx, float freq_rx,
#                               uint8_t ctcss_tx, uint8_t squelch, uint8_t ctcss_rx
FRAME_GROUP   = make_frame(CMD_OUT_GROUP,
                           struct.pack("<BffBBB", 0, 146.52, 146.52, 0, 1, 0))

# ── Incoming frame parser ───────────────────────────────────────────────────

class FrameParser:
    """Streaming byte-level parser that reconstructs ESP32 protocol frames."""

    def __init__(self):
        self._buf = bytearray()
        self._reset()

    def _reset(self):
        self._delim_pos = 0
        self._cmd = None
        self._param_len = None
        self._param_len_lo = None
        self._params = bytearray()
        self._state = "DELIM"

    def feed(self, data: bytes) -> list[tuple[int, bytes]]:
        """Feed raw bytes; returns list of (cmd, params) tuples for complete frames."""
        frames = []
        for b in data:
            result = self._process_byte(b)
            if result is not None:
                frames.append(result)
        return frames

    def _process_byte(self, b: int):
        if self._state == "DELIM":
            if b == DELIMITER[self._delim_pos]:
                self._delim_pos += 1
                if self._delim_pos == 4:
                    self._state = "CMD"
                    self._delim_pos = 0
            else:
                # Restart match; byte might be start of a new delimiter
                self._delim_pos = 1 if b == DELIMITER[0] else 0
        elif self._state == "CMD":
            self._cmd = b
            self._state = "LEN_LO"
        elif self._state == "LEN_LO":
            self._param_len_lo = b
            self._state = "LEN_HI"
        elif self._state == "LEN_HI":
            self._param_len = self._param_len_lo | (b << 8)
            self._params = bytearray()
            if self._param_len == 0:
                frame = (self._cmd, bytes(self._params))
                self._reset()
                return frame
            self._state = "PARAMS"
        elif self._state == "PARAMS":
            self._params.append(b)
            if len(self._params) == self._param_len:
                frame = (self._cmd, bytes(self._params))
                self._reset()
                return frame
        return None


# ── Helpers ─────────────────────────────────────────────────────────────────

def ts() -> str:
    return f"{time.time():.3f}"

def parse_version(params: bytes) -> dict:
    """Parse VERSION frame payload (9 bytes on ESP32)."""
    if len(params) < 9:
        return {}
    ver, radio_status, window_size, rf_type, features = struct.unpack_from("<HcIBB", params)
    return {
        "ver": ver,
        "radio_status": radio_status.decode("latin1"),
        "window_size": window_size,
        "rf_type": rf_type,
        "features": features,
    }

def parse_window_update(params: bytes) -> int:
    """Parse WINDOW_UPDATE payload (4-byte size_t on ESP32)."""
    if len(params) < 4:
        return -1
    return struct.unpack_from("<I", params)[0]


def decode_debug(params: bytes) -> str:
    try:
        return params.decode("utf-8", errors="replace").rstrip()
    except Exception:
        return repr(params)


# ── Core test logic ─────────────────────────────────────────────────────────

CRASH_REASONS = [
    "Exception/Panic Reset",
    "Interrupt Watchdog Reset",
    "Task Watchdog Reset",
    "Other Watchdog Reset",
]


def run_test(port: str, baud: int = 115200, timeout: int = 10) -> int:
    """
    Run the handshake test sequence.

    Returns:
      0 = pass
      1 = crash detected
      2 = timeout / no response
    """
    print(f"[{ts()}] Opening {port} at {baud} baud ...")
    try:
        ser = serial.Serial(port, baud, timeout=0.05,
                            dsrdtr=False, rtscts=False)
    except serial.SerialException as e:
        print(f"ERROR: Cannot open {port}: {e}", file=sys.stderr)
        return 2

    # Reset the ESP32 via the auto-reset circuit (same as esptool does).
    # Without this, if the device is already running we won't see HELLO,
    # and if the port-open happens to toggle DTR we might miss the boot window.
    ser.dtr = False; ser.rts = True;  time.sleep(0.1)   # assert reset
    ser.dtr = True;  ser.rts = False; time.sleep(0.1)   # boot normally
    ser.dtr = False                                       # idle

    parser = FrameParser()

    # ── Internal helpers ────────────────────────────────────────────────────

    def drain(seconds: float = 8.0):
        """
        Drain startup output until HELLO is received (setup() complete) or timeout.
        Returns True if HELLO was seen, False if we timed out.
        """
        deadline = time.time() + seconds
        raw_total = 0
        while time.time() < deadline:
            raw = ser.read(256)
            if not raw:
                continue
            raw_total += len(raw)
            for cmd, params in parser.feed(raw):
                _print_frame(cmd, params)
                if cmd == CMD_IN_HELLO:
                    print(f"  [{ts()}] HELLO received — firmware ready "
                          f"({raw_total} raw bytes seen)")
                    return True
        if raw_total == 0:
            print(f"  [{ts()}] WARNING: zero bytes received during drain "
                  f"— check port and connections")
        else:
            print(f"  [{ts()}] NOTE: {raw_total} raw bytes received but no "
                  f"HELLO frame parsed (device may already be running)")
        return False

    def _print_frame(cmd: int, params: bytes):
        name = CMD_IN_NAMES.get(cmd, f"0x{cmd:02X}")
        if cmd in (CMD_IN_DEBUG_INFO, CMD_IN_DEBUG_ERROR,
                   CMD_IN_DEBUG_WARN, CMD_IN_DEBUG_DEBUG, CMD_IN_DEBUG_TRACE):
            text = decode_debug(params)
            print(f"  [{ts()}] {name}: {text}")
        elif cmd == CMD_IN_VERSION:
            v = parse_version(params)
            print(f"  [{ts()}] {name}: ver={v.get('ver')} radio={v.get('radio_status')} "
                  f"window={v.get('window_size')} rf_type={v.get('rf_type')} "
                  f"features=0x{v.get('features', 0):02X}")
        elif cmd == CMD_IN_WINDOW_UPDATE:
            size = parse_window_update(params)
            print(f"  [{ts()}] {name}: size={size}")
        elif cmd == CMD_IN_HELLO:
            print(f"  [{ts()}] {name}")
        elif cmd == CMD_IN_RX_AUDIO:
            print(f"  [{ts()}] {name}: {len(params)} bytes (audio)")
        else:
            print(f"  [{ts()}] {name}: {params.hex() if params else '(no params)'}")

    def wait_for(target_cmd: int, deadline: float, extra_cmds: set | None = None
                 ) -> tuple[bool, bytes]:
        """
        Read frames until target_cmd is received or deadline passes.
        Returns (found, params).  Prints all received frames.
        Also watches for crash indicators in debug text.
        """
        if extra_cmds is None:
            extra_cmds = set()
        while time.time() < deadline:
            raw = ser.read(256)
            if not raw:
                continue
            for cmd, params in parser.feed(raw):
                _print_frame(cmd, params)
                # Crash detection: unexpected HELLO means firmware rebooted
                if cmd == CMD_IN_HELLO:
                    print(f"\n[{ts()}] *** CRASH DETECTED: unexpected HELLO (firmware rebooted) ***\n")
                    return False, b""
                # Crash detection in debug lines
                if cmd in (CMD_IN_DEBUG_INFO, CMD_IN_DEBUG_ERROR, CMD_IN_DEBUG_WARN):
                    text = decode_debug(params)
                    for reason in CRASH_REASONS:
                        if reason in text:
                            print(f"\n[{ts()}] *** CRASH DETECTED in debug log: {reason} ***\n")
                            return False, b""
                if cmd == target_cmd or cmd in extra_cmds:
                    return True, params
        return False, b""

    def send(label: str, frame: bytes):
        print(f"[{ts()}] --> {label} ({len(frame)} bytes)")
        ser.write(frame)
        ser.flush()

    # ── Step 0: wait for firmware ready (HELLO at end of setup()) ───────────
    print(f"[{ts()}] Waiting for HELLO / firmware ready (up to 8 s) ...")
    hello_seen = drain(8.0)
    if not hello_seen:
        print(f"  [{ts()}] NOTE: HELLO not seen — device may already be running, proceeding anyway")

    # ── Step 1: STOP ────────────────────────────────────────────────────────
    send("STOP", FRAME_STOP)
    print(f"[{ts()}]     Waiting for WINDOW_UPDATE ...")
    ok, _ = wait_for(CMD_IN_WINDOW_UPDATE, time.time() + timeout)
    if not ok:
        print(f"\n[{ts()}] TIMEOUT: no WINDOW_UPDATE after STOP", file=sys.stderr)
        ser.close()
        return 2

    # ── Step 2: CONFIG ──────────────────────────────────────────────────────
    send("CONFIG", FRAME_CONFIG)
    # CONFIG triggers the radio handshake — can take up to ~20 s.
    config_deadline = time.time() + max(timeout, 25)
    print(f"[{ts()}]     Waiting for VERSION (radio handshake may take up to 20 s) ...")
    ok, version_params = wait_for(CMD_IN_VERSION, config_deadline,
                                  extra_cmds={CMD_IN_WINDOW_UPDATE})
    if not ok:
        print(f"\n[{ts()}] TIMEOUT: no VERSION after CONFIG", file=sys.stderr)
        ser.close()
        return 2
    # Also drain WINDOW_UPDATE that follows VERSION
    wait_for(CMD_IN_WINDOW_UPDATE, time.time() + 2)

    # ── Step 3: RSSI enable ─────────────────────────────────────────────────
    send("RSSI_ON", FRAME_RSSI_ON)
    print(f"[{ts()}]     Waiting for WINDOW_UPDATE ...")
    ok, _ = wait_for(CMD_IN_WINDOW_UPDATE, time.time() + timeout)
    if not ok:
        print(f"\n[{ts()}] TIMEOUT: no WINDOW_UPDATE after RSSI_ON", file=sys.stderr)
        ser.close()
        return 2

    # ── Step 4: GROUP ───────────────────────────────────────────────────────
    send("GROUP", FRAME_GROUP)
    monitor_end = time.time() + 5
    print(f"[{ts()}]     Monitoring for 5 s — watching for alive signal or crash ...")

    got_window_update = False
    crashed = False
    stack_hwm_reported = False

    while time.time() < monitor_end:
        raw = ser.read(256)
        if not raw:
            continue
        for cmd, params in parser.feed(raw):
            _print_frame(cmd, params)
            if cmd == CMD_IN_WINDOW_UPDATE:
                got_window_update = True
            if cmd == CMD_IN_HELLO:
                print(f"\n[{ts()}] *** CRASH DETECTED: unexpected HELLO (firmware rebooted) ***\n")
                crashed = True
            if cmd in (CMD_IN_DEBUG_INFO, CMD_IN_DEBUG_ERROR, CMD_IN_DEBUG_WARN):
                text = decode_debug(params)
                # Stack health
                if "Stack HWM:" in text:
                    stack_hwm_reported = True
                # Loop timing
                if "Loop Time:" in text:
                    pass  # already printed by _print_frame
                # Crash via reboot indicator
                for reason in CRASH_REASONS:
                    if reason in text:
                        print(f"\n[{ts()}] *** CRASH DETECTED: {reason} ***\n")
                        crashed = True
                        break

    ser.close()

    # ── Result ───────────────────────────────────────────────────────────────
    print()
    if crashed:
        print(f"[{ts()}] RESULT: FAIL — crash detected after GROUP")
        return 1

    if not got_window_update:
        print(f"[{ts()}] RESULT: FAIL — no WINDOW_UPDATE in 5 s after GROUP (likely crash)")
        return 1

    if not stack_hwm_reported:
        print(f"[{ts()}] NOTE: no Stack HWM log received — "
              "ensure firmware is non-RELEASE build with debugLoop() active")

    print(f"[{ts()}] RESULT: PASS — firmware alive ≥5 s after GROUP")
    return 0


# ── Entry point ─────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="KV4P-HT serial protocol handshake test harness")
    parser.add_argument("--port", required=True,
                        help="Serial port, e.g. /dev/cu.usbserial-XXXX")
    parser.add_argument("--baud", type=int, default=115200,
                        help="Baud rate (default: 115200)")
    parser.add_argument("--timeout", type=int, default=10,
                        help="Per-step timeout in seconds (default: 10; "
                             "CONFIG step always gets at least 25 s)")
    args = parser.parse_args()

    exit_code = run_test(args.port, args.baud, args.timeout)
    print(f"\nExit code: {exit_code}  "
          f"({'PASS' if exit_code == 0 else 'CRASH' if exit_code == 1 else 'TIMEOUT/NO-RESPONSE'})")
    sys.exit(exit_code)


if __name__ == "__main__":
    main()
