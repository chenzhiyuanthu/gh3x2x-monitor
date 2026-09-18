/*
 * XIAO nRF52840 Sense platform layer for the Goodix GH3x2x V4300 driver/algorithm demo.
 *
 * Wiring (EVK mainboard H6 "外接模组 DIP" header → XIAO; STM32 NRST tied to GND on SWD_MCU):
 *   H6 SCLK  → D8  (SCK)
 *   H6 MISO  → D9  (MISO)
 *   H6 MOSI  → D10 (MOSI)
 *   H6 CS    → D2
 *   H6 INT   → D1
 *   H6 RST   → D3
 *   H6 GND   → GND
 * The EVK board keeps powering the module (AVDD/VDDIO 3.3 V, VLED 5 V). XIAO IO is 3.3 V.
 */
#include <Arduino.h>
#include <SPI.h>
#include <ArduinoBLE.h>
#include "LSM6DS3.h"
#include "xiao_hal.h"
#include "xiao_app.h"

// ---------------------------------------------------------------- pins
static const int PIN_GH_CS  = D2;
static const int PIN_GH_INT = D1;
static const int PIN_GH_RST = D3;

// ---------------------------------------------------------------- SPI
static SPISettings ghSpi(4000000, MSBFIRST, SPI_MODE0);

void xiao_spi_init(void) {
    pinMode(PIN_GH_CS, OUTPUT);
    digitalWrite(PIN_GH_CS, HIGH);
    SPI.begin();
}

static uint8_t spiTmp[256];

void xiao_spi_write(uint8_t *buf, uint16_t len) {
    // mbed SPI transfer(buf, n) is in-place; copy so the caller's buffer stays intact.
    SPI.beginTransaction(ghSpi);
    while (len) {
        uint16_t n = len > sizeof(spiTmp) ? sizeof(spiTmp) : len;
        memcpy(spiTmp, buf, n);
        SPI.transfer(spiTmp, n);
        buf += n; len -= n;
    }
    SPI.endTransaction();
}

void xiao_spi_read(uint8_t *buf, uint16_t len) {
    SPI.beginTransaction(ghSpi);
    memset(buf, 0x00, len);
    SPI.transfer(buf, len);
    SPI.endTransaction();
}

void xiao_spi_cs(uint8_t level) { digitalWrite(PIN_GH_CS, level ? HIGH : LOW); }

// ---------------------------------------------------------------- reset / interrupt
void xiao_reset_pin_init(void) {
    pinMode(PIN_GH_RST, OUTPUT);
    digitalWrite(PIN_GH_RST, HIGH);
}
void xiao_reset_pin(uint8_t level) { digitalWrite(PIN_GH_RST, level ? HIGH : LOW); }

volatile bool g_ghIntPending = false;
static void ghIntIsr() {
    g_ghIntPending = true;
    hal_gh3x2x_int_handler_call_back();
}

void xiao_int_init(void) {
    pinMode(PIN_GH_INT, INPUT_PULLDOWN);
    attachInterrupt(digitalPinToInterrupt(PIN_GH_INT), ghIntIsr, RISING);
}
void xiao_int_callback(void) { /* flag already set in ISR */ }

// ---------------------------------------------------------------- log / delay
void xiao_log(const char *s) { if (Serial) Serial.print(s); }
void xiao_delay_us(uint16_t us) { delayMicroseconds(us); }
void xiao_delay_ms(uint16_t ms) { delay(ms); }

// ---------------------------------------------------------------- G-sensor (LSM6DS3TR-C on the XIAO Sense)
// The driver wants 512 LSB/g (GSENSOR_SENSITIVITY_512_COUNTS_PER_G). LSM6DS3 at ±4 g is 0.122 mg/LSB
// (8192 LSB/g) → divide raw by 16. Sampled at 25 Hz to match the PPG frame rate (sync read mode).
static LSM6DS3 imu(I2C_MODE, 0x6A);
static bool imuOK = false;
static volatile bool gsCaching = false;
struct GsRaw { int16_t x, y, z; };
static const int GS_RING = 256;
static GsRaw gsRing[GS_RING];
static volatile uint16_t gsHead = 0, gsTail = 0;
static unsigned long gsNextAt = 0;
static const unsigned long GS_PERIOD_US = 40000;   // 25 Hz

bool xiao_imu_begin() {
#ifdef PIN_LSM6DS3TR_C_POWER
    pinMode(PIN_LSM6DS3TR_C_POWER, OUTPUT);
    digitalWrite(PIN_LSM6DS3TR_C_POWER, HIGH);
    delay(50);
#endif
    imu.settings.accelRange = 4;
    imu.settings.accelSampleRate = 104;
    imu.settings.gyroEnabled = 0;
    imu.settings.accelBandWidth = 50;
    imuOK = (imu.begin() == 0);
    return imuOK;
}

void xiao_imu_poll() {
    if (!imuOK) return;
    unsigned long now = micros();
    if ((long)(now - gsNextAt) < 0) return;
    gsNextAt = now + GS_PERIOD_US;
    if (!gsCaching) return;
    GsRaw s;
    s.x = imu.readRawAccelX() / 16;
    s.y = imu.readRawAccelY() / 16;
    s.z = imu.readRawAccelZ() / 16;
    uint16_t next = (gsHead + 1) % GS_RING;
    if (next == gsTail) gsTail = (gsTail + 1) % GS_RING;   // overwrite oldest
    gsRing[gsHead] = s;
    gsHead = next;
}

void xiao_gs_start_cache(void) { gsHead = gsTail = 0; gsCaching = true; }
void xiao_gs_stop_cache(void) { gsCaching = false; }

void xiao_gs_get_fifo(void *gsensor_buffer, uint16_t *gsensor_buffer_index) {
    // STGsensorRawdata is {GS16 x, y, z} (gyro disabled in gh_demo_config.h)
    int16_t *out = (int16_t *)gsensor_buffer;
    uint16_t n = 0;
    while (gsTail != gsHead && n < XIAO_GS_MAX_POINTS) {
        out[3 * n] = gsRing[gsTail].x;
        out[3 * n + 1] = gsRing[gsTail].y;
        out[3 * n + 2] = gsRing[gsTail].z;
        gsTail = (gsTail + 1) % GS_RING;
        n++;
    }
    *gsensor_buffer_index = n;
}

// ---------------------------------------------------------------- BLE (Goodix GHealth profile)
static BLEService ghService("0000190E-0000-1000-8000-00805F9B34FB");
static BLECharacteristic ghTx("00000003-0000-1000-8000-00805F9B34FB", BLERead | BLENotify, 244);
static BLECharacteristic ghRx("00000004-0000-1000-8000-00805F9B34FB", BLEWrite | BLEWriteWithoutResponse, 244);
static bool bleConnected = false;
static uint32_t txPackets = 0;

static void onRxWritten(BLEDevice, BLECharacteristic chr) {
    int len = chr.valueLength();
    if (len <= 0) return;
    uint8_t buf[244];
    chr.readValue(buf, len);
    if (Serial) { Serial.print("[BLE rx] len="); Serial.print(len); Serial.print(" cmd=0x"); Serial.println(len > 2 ? buf[2] : 0, HEX); }
    Gh3x2xDemoProtocolProcess(buf, (uint16_t)len);
}

bool xiao_ble_begin() {
    if (!BLE.begin()) return false;
    BLE.setLocalName("GH-XIAO");
    BLE.setDeviceName("GH-XIAO");
    BLE.setAdvertisedService(ghService);
    ghService.addCharacteristic(ghTx);
    ghService.addCharacteristic(ghRx);
    ghRx.setEventHandler(BLEWritten, onRxWritten);
    BLE.addService(ghService);
    BLE.setConnectionInterval(12, 24);   // 15–30 ms
    BLE.advertise();
    return true;
}

void xiao_ble_poll() {
    BLE.poll();
    BLEDevice c = BLE.central();
    bool now = c && c.connected();
    if (now != bleConnected) {
        bleConnected = now;
        if (now) { Serial.print("[BLE] central connected: "); Serial.println(c.address()); }
        else Serial.println("[BLE] central disconnected");
        digitalWrite(LED_BUILTIN, now ? LOW : HIGH);
    }
}

bool xiao_ble_connected() { return bleConnected; }
uint32_t xiao_ble_tx_count() { return txPackets; }

void xiao_serial_send(uint8_t *buf, uint16_t len) {
    if (!bleConnected || len == 0) return;
    if (len > 244) len = 244;
    ghTx.writeValue(buf, len);
    txPackets++;
    if (Serial && txPackets <= 20) { Serial.print("[BLE tx] len="); Serial.print(len); Serial.print(" cmd=0x"); Serial.println(buf[2], HEX); }
}

// The protocol send timer (__GH3X2X_PROTOCOL_SEND_TIMER_PERIOD__), driven from loop(). One packet per tick.
// Goodix: the period must be longer than the BLE connection interval (15–30 ms here) — the nRF52 controller only
// holds a few ACL buffers, and a burst of packets faster than the link drains them is silently dropped.
static bool serialTimerOn = false;
static unsigned long serialNextAt = 0;
static uint16_t serialPeriod = 40;
void xiao_serial_timer_start(uint16_t period_ms) { serialPeriod = period_ms ? period_ms : 40; serialTimerOn = true; serialNextAt = millis(); }
void xiao_serial_timer_stop(void) { serialTimerOn = false; }
void xiao_serial_timer_poll() {
    if (!serialTimerOn) return;
    unsigned long now = millis();
    if ((long)(now - serialNextAt) < 0) return;
    serialNextAt = now + serialPeriod;
    Gh3x2xSerialSendTimerHandle();
}

// Multi-sensor wear timer (GhMultiSensorTimerHandle) — driven from loop().
static bool msTimerOn = false;
static uint32_t msPeriod = 1000;
static unsigned long msNextAt = 0;
void xiao_ms_timer_create(uint32_t period_ms) { msPeriod = period_ms ? period_ms : 1000; }
void xiao_ms_timer_start(void) { msTimerOn = true; msNextAt = millis() + msPeriod; }
void xiao_ms_timer_stop(void) { msTimerOn = false; }
void xiao_ms_timer_delete(void) { msTimerOn = false; }
void xiao_ms_timer_poll() {
    if (!msTimerOn) return;
    unsigned long now = millis();
    if ((long)(now - msNextAt) < 0) return;
    msNextAt = now + msPeriod;
    GhMultiSensorTimerHandle();
}
