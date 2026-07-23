#include "BluetoothA2DPSink.h"
BluetoothA2DPSink a2dp_sink;

void setup() {
    i2s_pin_config_t pins = {
        .bck_io_num = 26,   // BCK
        .ws_io_num = 25,    // LRCK
        .data_out_num = 22, // DIN
        .data_in_num = I2S_PIN_NO_CHANGE
    };
    a2dp_sink.set_pin_config(pins);
    a2dp_sink.start("speek-rx");
}
void loop() {}
