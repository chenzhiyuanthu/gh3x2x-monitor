/* Platform functions implemented in platform_xiao.cpp (Arduino / mbed, XIAO nRF52840 Sense). C linkage. */
#ifndef XIAO_HAL_H
#define XIAO_HAL_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
void     xiao_spi_init(void);
void     xiao_spi_write(uint8_t *buf, uint16_t len);
void     xiao_spi_read(uint8_t *buf, uint16_t len);
void     xiao_spi_cs(uint8_t level);
void     xiao_reset_pin_init(void);
void     xiao_reset_pin(uint8_t level);
void     xiao_int_init(void);
void     xiao_int_callback(void);
void     xiao_log(const char *s);
void     xiao_delay_us(uint16_t us);
void     xiao_delay_ms(uint16_t ms);
void     xiao_gs_start_cache(void);
void     xiao_gs_stop_cache(void);
void     xiao_gs_get_fifo(void *gsensor_buffer, uint16_t *gsensor_buffer_index);
void     xiao_serial_send(uint8_t *buf, uint16_t len);
void     xiao_serial_timer_start(uint16_t period_ms);
void     xiao_serial_timer_stop(void);
void     xiao_ms_timer_create(uint32_t period_ms);
void     xiao_ms_timer_start(void);
void     xiao_ms_timer_stop(void);
void     xiao_ms_timer_delete(void);
#ifdef __cplusplus
}
#endif
#endif
