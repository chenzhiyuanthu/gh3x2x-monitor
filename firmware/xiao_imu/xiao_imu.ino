/*
 * XIAO nRF52840 Sense — 6-axis IMU streamer over BLE for GH Monitor.
 *
 * Advertises as "XIAO-IMU" with service 7A1D0001-... and a notify characteristic 7A1D0002-...
 * Packet (little-endian):
 *   u8  seq            packet sequence number
 *   u8  n              samples in this packet (8)
 *   u16 t_ms           millis() of the first sample (low 16 bits)
 *   n × { i16 ax, ay, az, gx, gy, gz }   raw LSM6DS3TR-C values
 * Scale: accel ±4 g → 0.122 mg/LSB ; gyro ±500 dps → 17.5 mdps/LSB ; sample rate 50 Hz.
 */
#include <ArduinoBLE.h>
#include <Wire.h>
#include "LSM6DS3.h"

static const char* SERVICE_UUID = "7A1D0001-2B7E-4C9B-9E2F-3C1A0D5E6F70";
static const char* DATA_UUID    = "7A1D0002-2B7E-4C9B-9E2F-3C1A0D5E6F70";
static const int   SAMPLE_PERIOD_MS = 20;      // 50 Hz
static const int   SAMPLES_PER_PACKET = 8;     // 4 + 8*12 = 100 bytes

LSM6DS3 imu(I2C_MODE, 0x6A);
BLEService imuService(SERVICE_UUID);
BLECharacteristic imuData(DATA_UUID, BLERead | BLENotify, 4 + SAMPLES_PER_PACKET * 12);

uint8_t packet[4 + SAMPLES_PER_PACKET * 12];
uint8_t seq = 0;
int     nInPacket = 0;
unsigned long nextSampleAt = 0;

static void put16(uint8_t* p, int16_t v) { p[0] = (uint8_t)(v & 0xFF); p[1] = (uint8_t)((v >> 8) & 0xFF); }

void setup() {
  Serial.begin(115200);
  pinMode(LED_BUILTIN, OUTPUT);
  digitalWrite(LED_BUILTIN, HIGH);   // LED off (active low)

#ifdef PIN_LSM6DS3TR_C_POWER
  pinMode(PIN_LSM6DS3TR_C_POWER, OUTPUT);
  digitalWrite(PIN_LSM6DS3TR_C_POWER, HIGH);
  delay(50);
#endif

  imu.settings.accelRange = 4;         // ±4 g
  imu.settings.accelSampleRate = 104;  // Hz (chip ODR; we read at 50 Hz)
  imu.settings.gyroRange = 500;        // ±500 dps
  imu.settings.gyroSampleRate = 104;
  imu.settings.accelBandWidth = 50;
  if (imu.begin() != 0) {
    Serial.println("IMU init failed");
    while (true) { digitalWrite(LED_BUILTIN, !digitalRead(LED_BUILTIN)); delay(100); }
  }

  if (!BLE.begin()) {
    Serial.println("BLE init failed");
    while (true) { digitalWrite(LED_BUILTIN, !digitalRead(LED_BUILTIN)); delay(300); }
  }
  BLE.setLocalName("XIAO-IMU");
  BLE.setDeviceName("XIAO-IMU");
  BLE.setAdvertisedService(imuService);
  imuService.addCharacteristic(imuData);
  BLE.addService(imuService);
  BLE.setConnectionInterval(12, 24);   // 15–30 ms
  BLE.advertise();
  Serial.println("XIAO-IMU advertising");
}

void loop() {
  BLE.poll();
  BLEDevice central = BLE.central();
  bool connected = central && central.connected();
  digitalWrite(LED_BUILTIN, connected ? LOW : HIGH);

  unsigned long now = millis();
  if ((long)(now - nextSampleAt) < 0) return;
  nextSampleAt = now + SAMPLE_PERIOD_MS;

  if (nInPacket == 0) {
    packet[0] = seq;
    packet[1] = SAMPLES_PER_PACKET;
    packet[2] = (uint8_t)(now & 0xFF);
    packet[3] = (uint8_t)((now >> 8) & 0xFF);
  }
  uint8_t* p = packet + 4 + nInPacket * 12;
  put16(p + 0,  imu.readRawAccelX());
  put16(p + 2,  imu.readRawAccelY());
  put16(p + 4,  imu.readRawAccelZ());
  put16(p + 6,  imu.readRawGyroX());
  put16(p + 8,  imu.readRawGyroY());
  put16(p + 10, imu.readRawGyroZ());
  nInPacket++;

  if (nInPacket >= SAMPLES_PER_PACKET) {
    if (connected) imuData.writeValue(packet, sizeof(packet));
    seq++;
    nInPacket = 0;
  }
}
