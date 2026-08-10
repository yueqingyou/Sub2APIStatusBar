#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

void monitor_events_initialize(void);
void monitor_events_notify(void);
void monitor_events_notify_from_isr(void);
void monitor_events_wait(uint32_t timeout_milliseconds);

#ifdef __cplusplus
}
#endif
