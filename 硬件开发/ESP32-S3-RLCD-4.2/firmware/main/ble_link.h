#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

#ifndef MONITOR_FIRMWARE_VERSION_MAJOR
#define MONITOR_FIRMWARE_VERSION_MAJOR 0
#define MONITOR_FIRMWARE_VERSION_MINOR 9
#define MONITOR_FIRMWARE_VERSION_PATCH 4
#define MONITOR_FIRMWARE_VERSION_STRING "0.9.4"
#endif

#define BLE_LINK_PAGE_COUNT 4
#define BLE_LINK_BATTERY_SAMPLE_INTERVAL_MIN_SECONDS 300U
#define BLE_LINK_BATTERY_SAMPLE_INTERVAL_MAX_SECONDS 86400U
#define BLE_LINK_BATTERY_SAMPLE_INTERVAL_DEFAULT_SECONDS 900U

typedef enum {
    BLE_LINK_STATE_STARTING = 0,
    BLE_LINK_STATE_UNPAIRED,
    BLE_LINK_STATE_ADVERTISING,
    BLE_LINK_STATE_PAIRING,
    BLE_LINK_STATE_SECURING,
    BLE_LINK_STATE_CONNECTED,
    BLE_LINK_STATE_READY,
    BLE_LINK_STATE_ERROR,
} ble_link_state_t;

typedef struct {
    ble_link_state_t state;
    bool connected;
    bool handshake_ready;
    bool encrypted;
    bool bonded;
    bool pairing_window_open;
    uint8_t current_page;
    int last_error;
} ble_link_snapshot_t;

typedef struct {
    bool mac_online;
    bool network_online;
    bool tokenrouter_online;
    bool data_stale;
    bool admin_mode;
    bool overview_valid;
    uint64_t overview_cost_microdollars;
    uint64_t overview_requests;
    uint64_t overview_tokens;
    uint16_t tasks_total;
    uint16_t tasks_done;
    uint16_t tasks_error;
    uint16_t tasks_stale;
    bool quota_five_hour_valid;
    bool quota_seven_day_valid;
    bool quota_five_hour_reset_valid;
    bool quota_seven_day_reset_valid;
    uint32_t quota_five_hour_basis_points;
    uint32_t quota_seven_day_basis_points;
    uint32_t quota_five_hour_reset_seconds;
    uint32_t quota_seven_day_reset_seconds;
    uint32_t offline_timeout_seconds;
    int64_t last_signal_us;
    int64_t page_updated_us[BLE_LINK_PAGE_COUNT];
    uint32_t revision;
} ble_link_monitor_data_t;

esp_err_t ble_link_start(void);
esp_err_t ble_link_open_pairing_window(uint32_t duration_seconds);
esp_err_t ble_link_set_current_page(uint8_t page);
void ble_link_tick(void);
ble_link_snapshot_t ble_link_snapshot(void);
ble_link_monitor_data_t ble_link_monitor_data(void);
uint32_t ble_link_battery_sample_interval_seconds(void);
const char *ble_link_state_name(ble_link_state_t state);

#ifdef __cplusplus
}
#endif
