#include "monitor_events.h"

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

namespace {

TaskHandle_t g_monitor_task = nullptr;

}  // namespace

extern "C" void monitor_events_initialize(void)
{
    g_monitor_task = xTaskGetCurrentTaskHandle();
}

extern "C" void monitor_events_notify(void)
{
    if (g_monitor_task != nullptr) {
        xTaskNotifyGive(g_monitor_task);
    }
}

extern "C" void IRAM_ATTR monitor_events_notify_from_isr(void)
{
    if (g_monitor_task == nullptr) {
        return;
    }
    BaseType_t higher_priority_task_woken = pdFALSE;
    vTaskNotifyGiveFromISR(g_monitor_task, &higher_priority_task_woken);
    if (higher_priority_task_woken == pdTRUE) {
        portYIELD_FROM_ISR();
    }
}

extern "C" void monitor_events_wait(uint32_t timeout_milliseconds)
{
    TickType_t timeout = pdMS_TO_TICKS(timeout_milliseconds);
    if (timeout_milliseconds > 0 && timeout == 0) {
        timeout = 1;
    }
    ulTaskNotifyTake(pdTRUE, timeout);
}
