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
#include <AudioTools.h>
#include <AudioTools/AudioCodecs/CodecOpus.h>
#include <driver/dac.h>
#include <esp_task_wdt.h>
#include "globals.h"
#include "protocol.h"
#include "debug.h"

// Custom Output to Forward Encoded Data to Serial
class SerialOutput : public AudioOutput {
public:
  size_t write(const uint8_t *data, size_t len) override {
    if (len > 0) {
      if (len > PROTO_MTU) {
        len = PROTO_MTU;
      }
      sendAudio((uint8_t*)data, len);
      return len;
    }
    return len;
  } 
};

#define DECAY_TIME 0.25  // seconds

class DCOffsetRemover : public AudioEffect {
public:
  DCOffsetRemover(float decay_time = 0.25f, float sample_rate = AUDIO_SAMPLE_RATE): prev_y(0.0f) {
    alpha = 1.0f - expf(-1.0f / (sample_rate * (decay_time / logf(2.0f))));
  }
  DCOffsetRemover(const DCOffsetRemover &) = default;
  effect_t process(effect_t input) {
    return active() ? remove_dc(input) : input;
  }
  DCOffsetRemover *clone() override {
    return new DCOffsetRemover(*this);
  }
private:
  float prev_y;
  float alpha;
  int16_t remove_dc(int16_t x) {
    prev_y = alpha * x + (1.0f - alpha) * prev_y;
    return x - (int16_t)prev_y;
  }
};

// ── Audio task state ────────────────────────────────────────────────────────
enum AudioTaskState { AUDIO_IDLE, AUDIO_RX, AUDIO_STOPPING };
volatile AudioTaskState audioTaskState = AUDIO_IDLE;
SemaphoreHandle_t audioIdleSem = NULL;
TaskHandle_t audioTaskHandle   = NULL;

bool rxStreamConfigured = false;
AnalogAudioStream in;
AudioInfo rxInfo(AUDIO_SAMPLE_RATE, 1, 16);
OpusAudioEncoder rxEnc;
SerialOutput rxAudioOutput;
EncodedAudioStream rxOut(&rxAudioOutput, &rxEnc);
AudioEffectStream effects(in);  
StreamCopy rxCopier(rxOut, effects);
Boost mute(0.0);
Boost gain(16.0);
DCOffsetRemover dcOffsetRemover(DECAY_TIME, AUDIO_SAMPLE_RATE);

inline void injectADCBias() {
  dac_output_enable(DAC_CHANNEL_2);  // GPIO26 (DAC1)
  dac_output_voltage(DAC_CHANNEL_2, (255.0 / 3.3) * hw.adcBias);
} 

inline void setUpADCAttenuator() {
  adc1_config_channel_atten(I2S_ADC_CHANNEL, hw.adcAttenuation);
}

// Called once early in setup() (before BLE/I2S consume heap) to pre-allocate the
// OpusEncoder.  Sets enc_out.active=true so later rxOut.begin() calls are no-ops.
void initRxCodec() {
  rxEnc.setAudioInfo(rxInfo);
  auto &encoderConfig = rxEnc.config();
  encoderConfig.application = OPUS_APPLICATION_AUDIO;
  encoderConfig.frame_sizes_ms_x2 = OPUS_FRAMESIZE_40_MS;
  encoderConfig.vbr = 1;
  encoderConfig.max_bandwidth = OPUS_BANDWIDTH_NARROWBAND;
  rxOut.begin(rxInfo);  // allocates OpusEncoder via enc_out.begin(); sets enc_out.active=true
}

void initI2SRx() {
  injectADCBias();
  setUpADCAttenuator();
  //AudioToolsLogger.begin(debugPrinter, AudioToolsLogLevel::Debug);
  auto config = in.defaultConfig(RX_MODE);
  config.copyFrom(rxInfo);
  config.is_auto_center_read = false; // We use dcOffsetRemover instead
  config.use_apll = true;
  config.auto_clear = false;
  config.adc_pin = hw.pins.pinAudioIn;
  config.sample_rate = AUDIO_SAMPLE_RATE * 1.02; // 2% over sample rate to avoid buffer underruns
  in.begin(config);
  // Encoder is pre-allocated by initRxCodec(); skip if already open to avoid
  // re-invoking opus_encoder_create() on a fragmented heap.
  if (!rxEnc.isOpen()) {
    rxEnc.setAudioInfo(rxInfo);
    auto &encoderConfig = rxEnc.config();
    encoderConfig.application = OPUS_APPLICATION_AUDIO;
    encoderConfig.frame_sizes_ms_x2 = OPUS_FRAMESIZE_40_MS;
    encoderConfig.vbr = 1;
    encoderConfig.max_bandwidth = OPUS_BANDWIDTH_NARROWBAND;
    rxEnc.begin(encoderConfig);
  }
  // effects
  effects.clear();
  effects.addEffect(dcOffsetRemover);
  effects.addEffect(gain);
  effects.addEffect(mute);
  effects.begin(rxInfo);
  // rxOut.begin() is a no-op when enc_out.active==true (encoder already running)
  rxOut.begin(rxInfo);
  rxStreamConfigured = true;
  audioTaskState = AUDIO_RX;
}

void endI2SRx() {
  if (rxStreamConfigured) {
    audioTaskState = AUDIO_STOPPING;
    if (audioIdleSem != NULL) {
      xSemaphoreTake(audioIdleSem, portMAX_DELAY);
    }
    // Do NOT call rxOut.end() — that destroys the OpusEncoder.
    // Keep it alive so the next initI2SRx() can reuse it without re-allocating
    // from the (now fragmented) heap.  Any partial buffered frame is discarded,
    // which is acceptable when stopping RX.
    effects.end();
    in.end();
  }
  rxStreamConfigured = false;
}
  
void rxAudioLoop() {
  if (mode == MODE_RX) {
    mute.setActive(squelched);
    rxCopier.copy();
    esp_task_wdt_reset();
  }
}

void audioTask(void *) {
  audioIdleSem = xSemaphoreCreateBinary();
  esp_task_wdt_add(NULL);
  while (true) {
    switch (audioTaskState) {
      case AUDIO_IDLE:
        esp_task_wdt_reset();
        vTaskDelay(1);
        break;
      case AUDIO_RX:
        mute.setActive(squelched);
        rxCopier.copy();
        esp_task_wdt_reset();
        {
          static uint32_t _lastHWM = 0;
          uint32_t _now = millis();
          if (_now - _lastHWM >= 1000) {
            _lastHWM = _now;
            _LOGI("AudioTask Stack HWM: %u bytes free", uxTaskGetStackHighWaterMark(NULL));
          }
        }
        break;
      case AUDIO_STOPPING:
        audioTaskState = AUDIO_IDLE;
        xSemaphoreGive(audioIdleSem);
        break;
    }
  }
}