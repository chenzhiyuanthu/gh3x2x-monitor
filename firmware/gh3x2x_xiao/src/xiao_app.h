/* Glue between the Arduino sketch / platform layer and the Goodix demo (C linkage). */
#ifndef XIAO_APP_H
#define XIAO_APP_H
#include <stdint.h>
#include <stdbool.h>
#define XIAO_GS_MAX_POINTS 300   /* must not exceed __GSENSOR_DATA_BUFFER_SIZE__ in gh_demo_config.h */
#ifdef __cplusplus
extern "C" {
#endif
/* Goodix demo API (demo_kernel_code/kernel/gh_demo.h etc.) */
int      Gh3x2xDemoInit(void);
void     Gh3x2xDemoInterruptProcess(void);
void     Gh3x2xDemoStartSampling(uint32_t unFuncMode);
void     Gh3x2xDemoStopSampling(uint32_t unFuncMode);
void     Gh3x2xDemoProtocolProcess(uint8_t *puchProtocolDataBuffer, uint16_t usRecvLen);
void     Gh3x2xSerialSendTimerHandle(void);
void     GhMultiSensorTimerHandle(void);
void     hal_gh3x2x_int_handler_call_back(void);
extern uint8_t g_uchGh3x2xIntCallBackIsCalled;
/* platform (platform_xiao.cpp) */
bool     xiao_imu_begin(void);
void     xiao_imu_poll(void);
bool     xiao_ble_begin(void);
void     xiao_ble_poll(void);
bool     xiao_ble_connected(void);
uint32_t xiao_ble_tx_count(void);
void     xiao_serial_timer_poll(void);
void     xiao_ms_timer_poll(void);
#ifdef __cplusplus
}
#endif
#endif
