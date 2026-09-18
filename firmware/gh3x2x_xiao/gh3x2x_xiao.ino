/*
 * GH3x2x on XIAO nRF52840 Sense — Goodix V4300 driver + algorithms (HR/HRV/SpO2/NADT/ADT)
 * with the on-board LSM6DS3 accelerometer feeding the algorithms, streaming to GH Monitor over BLE
 * using the Goodix protocol (advertises as "GH-XIAO").
 *
 * Build/flash: firmware/gh3x2x_xiao/build.sh
 */
#include "src/xiao_app.h"

// function bits (gh_drv.h): ADT 1<<0, HR 1<<1, HRV 1<<2, SPO2 1<<6, SOFT_ADT_GREEN 1<<9
static const uint32_t START_FUNCS = (1u << 0) | (1u << 1) | (1u << 2) | (1u << 6);

static bool sensorOK = false;
static bool bleOK = false;
static unsigned long lastStatus = 0;
static unsigned long lastRetry = 0;

void setup() {
  Serial.begin(115200);
  pinMode(LED_BUILTIN, OUTPUT);
  digitalWrite(LED_BUILTIN, HIGH);
  unsigned long t0 = millis();
  while (!Serial && millis() - t0 < 2500) {}
  Serial.println("\r\n=== GH3x2x on XIAO nRF52840 Sense (Goodix V4300) ===");

  Serial.print("IMU: "); Serial.println(xiao_imu_begin() ? "LSM6DS3 ok" : "FAILED (no motion data)");
  bleOK = xiao_ble_begin();
  Serial.print("BLE: "); Serial.println(bleOK ? "advertising GH-XIAO" : "FAILED");

  int ret = Gh3x2xDemoInit();
  sensorOK = (ret == 0);
  Serial.print("Gh3x2xDemoInit -> "); Serial.println(ret);
  if (sensorOK) {
    Gh3x2xDemoStartSampling(START_FUNCS);
    Serial.println("sampling ADT+HR+HRV+SPO2");
  } else {
    Serial.println("sensor init failed: check H6 wiring, EVK power, STM32 NRST->GND");
  }
}

void loop() {
  xiao_ble_poll();
  xiao_imu_poll();
  xiao_serial_timer_poll();
  xiao_ms_timer_poll();

  if (sensorOK && g_uchGh3x2xIntCallBackIsCalled) {
    Gh3x2xDemoInterruptProcess();
  }

  if (millis() - lastStatus > 5000) {
    lastStatus = millis();
    Serial.print("[status] ble="); Serial.print(bleOK ? (xiao_ble_connected() ? "connected" : "advertising") : "off");
    Serial.print(" sensor="); Serial.print(sensorOK ? "ok" : "init-failed");
    Serial.print(" tx="); Serial.println(xiao_ble_tx_count());
  }
  if (!sensorOK && millis() - lastRetry > 15000) {
    lastRetry = millis();
    int ret = Gh3x2xDemoInit();
    sensorOK = (ret == 0);
    Serial.print("retry Gh3x2xDemoInit -> "); Serial.println(ret);
    if (sensorOK) Gh3x2xDemoStartSampling(START_FUNCS);
  }
}
