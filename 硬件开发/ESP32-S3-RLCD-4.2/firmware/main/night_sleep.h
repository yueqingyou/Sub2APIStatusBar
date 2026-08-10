#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

#define NIGHT_SLEEP_DEFAULT_START_MINUTE 1410U
#define NIGHT_SLEEP_DEFAULT_END_MINUTE 450U

typedef enum {
    NIGHT_SLEEP_WAKEUP_UNKNOWN = 0,
    NIGHT_SLEEP_WAKEUP_TIMER = 1,
    NIGHT_SLEEP_WAKEUP_RTC_INTERRUPT = 2,
    NIGHT_SLEEP_WAKEUP_KEY = 3,
    NIGHT_SLEEP_WAKEUP_OTHER = 4,
} night_sleep_wakeup_reason_t;

typedef struct {
    bool enabled;
    bool clock_synchronized;
    bool manual_override;
    bool rtc_wake_fallback;
    bool boot_sequence_parity;
    night_sleep_wakeup_reason_t last_wakeup_reason;
    uint16_t start_minute;
    uint16_t end_minute;
} night_sleep_snapshot_t;

esp_err_t night_sleep_initialize(void);
esp_err_t night_sleep_apply_schedule(
    bool enabled,
    uint16_t start_minute,
    uint16_t end_minute,
    uint16_t year,
    uint8_t month,
    uint8_t day,
    uint8_t weekday,
    uint8_t hour,
    uint8_t minute,
    uint8_t second);
night_sleep_snapshot_t night_sleep_snapshot(void);
bool night_sleep_should_enter(void);
esp_err_t night_sleep_prepare_deep_sleep(void);
void night_sleep_start_deep_sleep(void);

#ifdef __cplusplus
}
#endif
