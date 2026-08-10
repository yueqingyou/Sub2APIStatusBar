#include "ble_link.h"

#include <string.h>

#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "host/ble_gatt.h"
#include "host/ble_hs.h"
#include "host/ble_sm.h"
#include "host/ble_store.h"
#include "host/util/util.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "nvs.h"
#include "nvs_flash.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"

#include "firmware_update.h"
#include "monitor_events.h"
#include "night_sleep.h"

#define BLE_PROTOCOL_VERSION 6
#define BLE_STATUS_PAYLOAD_LENGTH 20
#define BLE_MAX_BONDS 1
#define BLE_PACKET_HEADER_LENGTH 5
#define BLE_COMMON_PREFIX_LENGTH 9
#define BLE_PAGE_PAYLOAD_OFFSET (BLE_PACKET_HEADER_LENGTH + BLE_COMMON_PREFIX_LENGTH)
#define BLE_HELLO_PACKET_LENGTH 5
#define BLE_POWER_SCHEDULE_PACKET_LENGTH 18
#define BLE_HEARTBEAT_PACKET_LENGTH 14
#define BLE_OVERVIEW_PACKET_LENGTH 39
#define BLE_TASKS_PACKET_LENGTH 22
#define BLE_QUOTA_PACKET_LENGTH 31
#define BLE_DEVICE_PACKET_LENGTH 14
#define BLE_FIRMWARE_UPDATE_START_PACKET_LENGTH 44
#define BLE_FIRMWARE_UPDATE_COMMAND_PACKET_LENGTH 5
#define BLE_FIRMWARE_DATA_MAX_LENGTH 240
#define BLE_GATT_SCHEMA_VERSION 2

#define BLE_MESSAGE_HELLO 0x01
#define BLE_MESSAGE_HEARTBEAT 0x02
#define BLE_MESSAGE_POWER_SCHEDULE 0x03
#define BLE_MESSAGE_OVERVIEW 0x10
#define BLE_MESSAGE_TASKS 0x11
#define BLE_MESSAGE_QUOTA 0x12
#define BLE_MESSAGE_DEVICE 0x13

#define BLE_FIRMWARE_UPDATE_COMMAND_START 0x01
#define BLE_FIRMWARE_UPDATE_COMMAND_FINISH 0x02
#define BLE_FIRMWARE_UPDATE_COMMAND_ABORT 0x03
#define BLE_ADV_FAST_DURATION_MILLISECONDS 30000
#define BLE_ADV_FAST_INTERVAL_UNITS 32
#define BLE_ADV_SLOW_INTERVAL_UNITS 1636

_Static_assert(BLE_STATUS_PAYLOAD_LENGTH <= 20,
               "状态通知必须适配默认ATT MTU");
_Static_assert(BLE_POWER_SCHEDULE_PACKET_LENGTH <= 20,
               "休眠计划写入必须适配默认ATT MTU");

static const char *kTag = "ble_link";
static const char *kDeviceName = "TokenRouter Monitor";
static const ble_uuid16_t kGattServiceUuid = BLE_UUID16_INIT(0x1801);
static const ble_uuid16_t kServiceChangedCharacteristicUuid = BLE_UUID16_INIT(0x2a05);

/* BFB75D90-76B2-4BBF-803D-3A8DDE689207 */
static const ble_uuid128_t kServiceUuid = BLE_UUID128_INIT(
    0x07, 0x92, 0x68, 0xde, 0x8d, 0x3a, 0x3d, 0x80,
    0xbf, 0x4b, 0xb2, 0x76, 0x90, 0x5d, 0xb7, 0xbf);

/* EC17F230-4F00-4BFD-903D-66B5EFBB92F0 */
static const ble_uuid128_t kCommandCharacteristicUuid = BLE_UUID128_INIT(
    0xf0, 0x92, 0xbb, 0xef, 0xb5, 0x66, 0x3d, 0x90,
    0xfd, 0x4b, 0x00, 0x4f, 0x30, 0xf2, 0x17, 0xec);

/* FEE4D514-9AFD-4FBA-9737-D2FD6BDCBF2F */
static const ble_uuid128_t kStatusCharacteristicUuid = BLE_UUID128_INIT(
    0x2f, 0xbf, 0xdc, 0x6b, 0xfd, 0xd2, 0x37, 0x97,
    0xba, 0x4f, 0xfd, 0x9a, 0x14, 0xd5, 0xe4, 0xfe);

/* 0299C897-440C-4466-BFF3-934103A8601C */
static const ble_uuid128_t kFirmwareDataCharacteristicUuid = BLE_UUID128_INIT(
    0x1c, 0x60, 0xa8, 0x03, 0x41, 0x93, 0xf3, 0xbf,
    0x66, 0x44, 0x0c, 0x44, 0x97, 0xc8, 0x99, 0x02);

static portMUX_TYPE s_state_lock = portMUX_INITIALIZER_UNLOCKED;
static ble_link_snapshot_t s_snapshot = {
    .state = BLE_LINK_STATE_STARTING,
    .connected = false,
    .handshake_ready = false,
    .encrypted = false,
    .bonded = false,
    .pairing_window_open = false,
    .current_page = 0,
    .last_error = 0,
};
static ble_link_monitor_data_t s_monitor_data;
static uint32_t s_battery_sample_interval_seconds =
    BLE_LINK_BATTERY_SAMPLE_INTERVAL_DEFAULT_SECONDS;
static uint8_t s_own_addr_type;
static uint16_t s_status_value_handle;
static uint16_t s_conn_handle = BLE_HS_CONN_HANDLE_NONE;
static int64_t s_pairing_deadline_us;
static bool s_host_synced;
static bool s_gatt_schema_change_pending;
static uint16_t s_gatt_service_changed_handle;

typedef enum {
    BLE_ADV_PHASE_NONE = 0,
    BLE_ADV_PHASE_PAIRING,
    BLE_ADV_PHASE_FAST,
    BLE_ADV_PHASE_SLOW,
} ble_adv_phase_t;

static ble_adv_phase_t s_adv_phase;

void ble_store_config_init(void);

static void load_gatt_schema_state(void)
{
    nvs_handle_t handle = 0;
    esp_err_t result = nvs_open("ble_schema", NVS_READWRITE, &handle);
    if (result != ESP_OK) {
        ESP_LOGW(kTag, "GATT schema state unavailable: %s", esp_err_to_name(result));
        s_gatt_schema_change_pending = true;
        return;
    }

    uint8_t stored_version = 0;
    result = nvs_get_u8(handle, "gatt_db", &stored_version);
    nvs_close(handle);
    if (result != ESP_OK && result != ESP_ERR_NVS_NOT_FOUND) {
        ESP_LOGW(kTag, "GATT schema state read failed: %s", esp_err_to_name(result));
    }
    s_gatt_schema_change_pending = result != ESP_OK || stored_version != BLE_GATT_SCHEMA_VERSION;
}

static void persist_gatt_schema_version(void)
{
    nvs_handle_t handle = 0;
    esp_err_t result = nvs_open("ble_schema", NVS_READWRITE, &handle);
    if (result == ESP_OK) {
        result = nvs_set_u8(handle, "gatt_db", BLE_GATT_SCHEMA_VERSION);
    }
    if (result == ESP_OK) {
        result = nvs_commit(handle);
    }
    if (result == ESP_OK) {
        s_gatt_schema_change_pending = false;
        ESP_LOGI(kTag, "GATT schema version persisted: %u", (unsigned int)BLE_GATT_SCHEMA_VERSION);
    } else {
        ESP_LOGW(kTag, "GATT schema version persist failed: %s", esp_err_to_name(result));
    }
    if (handle != 0) {
        nvs_close(handle);
    }
}

static void notify_gatt_schema_changed(void)
{
    if (!s_gatt_schema_change_pending) {
        return;
    }
    ble_svc_gatt_changed(0x0001, 0xffff);
    ESP_LOGI(kTag, "GATT service change announced: schema=%u", (unsigned int)BLE_GATT_SCHEMA_VERSION);
}

static void resolve_gatt_service_changed_handle(void)
{
    const int result = ble_gatts_find_chr(
        &kGattServiceUuid.u,
        &kServiceChangedCharacteristicUuid.u,
        NULL,
        &s_gatt_service_changed_handle);
    if (result != 0) {
        ESP_LOGW(kTag, "GATT service change handle unavailable: rc=%d", result);
        s_gatt_service_changed_handle = 0;
    }
}

static void set_state(
    ble_link_state_t state,
    bool connected,
    bool handshake_ready,
    bool encrypted,
    bool bonded,
    bool pairing_window_open,
    int last_error)
{
    bool changed;
    portENTER_CRITICAL(&s_state_lock);
    changed = s_snapshot.state != state
        || s_snapshot.connected != connected
        || s_snapshot.handshake_ready != handshake_ready
        || s_snapshot.encrypted != encrypted
        || s_snapshot.bonded != bonded
        || s_snapshot.pairing_window_open != pairing_window_open
        || s_snapshot.last_error != last_error;
    s_snapshot.state = state;
    s_snapshot.connected = connected;
    s_snapshot.handshake_ready = handshake_ready;
    s_snapshot.encrypted = encrypted;
    s_snapshot.bonded = bonded;
    s_snapshot.pairing_window_open = pairing_window_open;
    s_snapshot.last_error = last_error;
    portEXIT_CRITICAL(&s_state_lock);
    if (changed) {
        monitor_events_notify();
    }
}

static void set_connection_handle(uint16_t conn_handle)
{
    portENTER_CRITICAL(&s_state_lock);
    s_conn_handle = conn_handle;
    portEXIT_CRITICAL(&s_state_lock);
}

static uint16_t connection_handle(void)
{
    uint16_t conn_handle;
    portENTER_CRITICAL(&s_state_lock);
    conn_handle = s_conn_handle;
    portEXIT_CRITICAL(&s_state_lock);
    return conn_handle;
}

static void set_host_synced(bool synced)
{
    portENTER_CRITICAL(&s_state_lock);
    s_host_synced = synced;
    portEXIT_CRITICAL(&s_state_lock);
}

static bool host_is_synced(void)
{
    bool synced;
    portENTER_CRITICAL(&s_state_lock);
    synced = s_host_synced;
    portEXIT_CRITICAL(&s_state_lock);
    return synced;
}

static void set_pairing_deadline(int64_t deadline_us)
{
    portENTER_CRITICAL(&s_state_lock);
    s_pairing_deadline_us = deadline_us;
    portEXIT_CRITICAL(&s_state_lock);
}

static bool pairing_window_is_open(void)
{
    int64_t deadline_us;
    portENTER_CRITICAL(&s_state_lock);
    deadline_us = s_pairing_deadline_us;
    portEXIT_CRITICAL(&s_state_lock);
    return deadline_us > esp_timer_get_time();
}

ble_link_snapshot_t ble_link_snapshot(void)
{
    ble_link_snapshot_t snapshot;
    portENTER_CRITICAL(&s_state_lock);
    snapshot = s_snapshot;
    portEXIT_CRITICAL(&s_state_lock);
    return snapshot;
}

ble_link_monitor_data_t ble_link_monitor_data(void)
{
    ble_link_monitor_data_t data;
    portENTER_CRITICAL(&s_state_lock);
    data = s_monitor_data;
    portEXIT_CRITICAL(&s_state_lock);
    return data;
}

uint32_t ble_link_battery_sample_interval_seconds(void)
{
    uint32_t interval_seconds;
    portENTER_CRITICAL(&s_state_lock);
    interval_seconds = s_battery_sample_interval_seconds;
    portEXIT_CRITICAL(&s_state_lock);
    return interval_seconds;
}

static uint16_t read_u16_le(const uint8_t *bytes)
{
    return (uint16_t)bytes[0] | ((uint16_t)bytes[1] << 8);
}

static uint32_t read_u32_le(const uint8_t *bytes)
{
    return (uint32_t)bytes[0]
        | ((uint32_t)bytes[1] << 8)
        | ((uint32_t)bytes[2] << 16)
        | ((uint32_t)bytes[3] << 24);
}

static uint64_t read_u64_le(const uint8_t *bytes)
{
    uint64_t value = 0;
    for (int index = 0; index < 8; ++index) {
        value |= (uint64_t)bytes[index] << (index * 8);
    }
    return value;
}

static bool apply_common_monitor_data(
    const uint8_t *common,
    int64_t received_us,
    bool *battery_interval_changed)
{
    const uint8_t flags = common[0];
    const bool network_online = (flags & 0x01) != 0;
    const bool tokenrouter_online = (flags & 0x02) != 0;
    const bool data_stale = (flags & 0x04) != 0;
    const bool admin_mode = (flags & 0x08) != 0;
    const uint32_t offline_timeout_seconds = read_u32_le(&common[1]);
    const uint32_t battery_sample_interval_seconds = read_u32_le(&common[5]);

    bool changed = !s_monitor_data.mac_online
        || s_monitor_data.network_online != network_online
        || s_monitor_data.tokenrouter_online != tokenrouter_online
        || s_monitor_data.data_stale != data_stale
        || s_monitor_data.admin_mode != admin_mode
        || s_monitor_data.offline_timeout_seconds != offline_timeout_seconds;
    s_monitor_data.mac_online = true;
    s_monitor_data.network_online = network_online;
    s_monitor_data.tokenrouter_online = tokenrouter_online;
    s_monitor_data.data_stale = data_stale;
    s_monitor_data.admin_mode = admin_mode;
    s_monitor_data.offline_timeout_seconds = offline_timeout_seconds;
    s_monitor_data.last_signal_us = received_us;
    *battery_interval_changed =
        s_battery_sample_interval_seconds != battery_sample_interval_seconds;
    s_battery_sample_interval_seconds = battery_sample_interval_seconds;
    return changed;
}

static int apply_monitor_packet(const uint8_t *packet, uint16_t length)
{
    const uint8_t message_type = packet[4];
    uint16_t expected_length;
    switch (message_type) {
    case BLE_MESSAGE_HEARTBEAT:
        expected_length = BLE_HEARTBEAT_PACKET_LENGTH;
        break;
    case BLE_MESSAGE_OVERVIEW:
        expected_length = BLE_OVERVIEW_PACKET_LENGTH;
        break;
    case BLE_MESSAGE_TASKS:
        expected_length = BLE_TASKS_PACKET_LENGTH;
        break;
    case BLE_MESSAGE_QUOTA:
        expected_length = BLE_QUOTA_PACKET_LENGTH;
        break;
    case BLE_MESSAGE_DEVICE:
        expected_length = BLE_DEVICE_PACKET_LENGTH;
        break;
    default:
        return BLE_ATT_ERR_UNLIKELY;
    }
    if (length != expected_length) {
        return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
    }

    const uint32_t battery_sample_interval_seconds = read_u32_le(
        &packet[BLE_PACKET_HEADER_LENGTH + 5]);
    if (battery_sample_interval_seconds < BLE_LINK_BATTERY_SAMPLE_INTERVAL_MIN_SECONDS
        || battery_sample_interval_seconds > BLE_LINK_BATTERY_SAMPLE_INTERVAL_MAX_SECONDS) {
        return BLE_ATT_ERR_VALUE_NOT_ALLOWED;
    }

    const int64_t received_us = esp_timer_get_time();
    bool changed;
    bool battery_interval_changed;

    portENTER_CRITICAL(&s_state_lock);
    changed = apply_common_monitor_data(
        &packet[BLE_PACKET_HEADER_LENGTH],
        received_us,
        &battery_interval_changed);

    switch (message_type) {
    case BLE_MESSAGE_HEARTBEAT:
        break;
    case BLE_MESSAGE_OVERVIEW:
        changed = changed
            || s_monitor_data.page_updated_us[0] == 0
            || s_monitor_data.overview_valid != (packet[BLE_PAGE_PAYLOAD_OFFSET] != 0)
            || s_monitor_data.overview_cost_microdollars
                != read_u64_le(&packet[BLE_PAGE_PAYLOAD_OFFSET + 1])
            || s_monitor_data.overview_requests
                != read_u64_le(&packet[BLE_PAGE_PAYLOAD_OFFSET + 9])
            || s_monitor_data.overview_tokens
                != read_u64_le(&packet[BLE_PAGE_PAYLOAD_OFFSET + 17]);
        s_monitor_data.overview_valid = packet[BLE_PAGE_PAYLOAD_OFFSET] != 0;
        s_monitor_data.overview_cost_microdollars =
            read_u64_le(&packet[BLE_PAGE_PAYLOAD_OFFSET + 1]);
        s_monitor_data.overview_requests =
            read_u64_le(&packet[BLE_PAGE_PAYLOAD_OFFSET + 9]);
        s_monitor_data.overview_tokens =
            read_u64_le(&packet[BLE_PAGE_PAYLOAD_OFFSET + 17]);
        s_monitor_data.page_updated_us[0] = received_us;
        break;
    case BLE_MESSAGE_TASKS:
        changed = changed
            || s_monitor_data.page_updated_us[1] == 0
            || s_monitor_data.tasks_total != read_u16_le(&packet[BLE_PAGE_PAYLOAD_OFFSET])
            || s_monitor_data.tasks_done != read_u16_le(&packet[BLE_PAGE_PAYLOAD_OFFSET + 2])
            || s_monitor_data.tasks_error != read_u16_le(&packet[BLE_PAGE_PAYLOAD_OFFSET + 4])
            || s_monitor_data.tasks_stale != read_u16_le(&packet[BLE_PAGE_PAYLOAD_OFFSET + 6]);
        s_monitor_data.tasks_total = read_u16_le(&packet[BLE_PAGE_PAYLOAD_OFFSET]);
        s_monitor_data.tasks_done = read_u16_le(&packet[BLE_PAGE_PAYLOAD_OFFSET + 2]);
        s_monitor_data.tasks_error = read_u16_le(&packet[BLE_PAGE_PAYLOAD_OFFSET + 4]);
        s_monitor_data.tasks_stale = read_u16_le(&packet[BLE_PAGE_PAYLOAD_OFFSET + 6]);
        s_monitor_data.page_updated_us[1] = received_us;
        break;
    case BLE_MESSAGE_QUOTA: {
        const uint8_t availability = packet[BLE_PAGE_PAYLOAD_OFFSET];
        const bool five_hour_valid = (availability & 0x01) != 0;
        const bool seven_day_valid = (availability & 0x02) != 0;
        const bool five_hour_reset_valid = (availability & 0x04) != 0;
        const bool seven_day_reset_valid = (availability & 0x08) != 0;
        changed = changed
            || s_monitor_data.page_updated_us[2] == 0
            || s_monitor_data.quota_five_hour_valid != five_hour_valid
            || s_monitor_data.quota_seven_day_valid != seven_day_valid
            || s_monitor_data.quota_five_hour_reset_valid != five_hour_reset_valid
            || s_monitor_data.quota_seven_day_reset_valid != seven_day_reset_valid
            || s_monitor_data.quota_five_hour_basis_points
                != read_u32_le(&packet[BLE_PAGE_PAYLOAD_OFFSET + 1])
            || s_monitor_data.quota_seven_day_basis_points
                != read_u32_le(&packet[BLE_PAGE_PAYLOAD_OFFSET + 5])
            || s_monitor_data.quota_five_hour_reset_seconds
                != read_u32_le(&packet[BLE_PAGE_PAYLOAD_OFFSET + 9])
            || s_monitor_data.quota_seven_day_reset_seconds
                != read_u32_le(&packet[BLE_PAGE_PAYLOAD_OFFSET + 13]);
        s_monitor_data.quota_five_hour_valid = five_hour_valid;
        s_monitor_data.quota_seven_day_valid = seven_day_valid;
        s_monitor_data.quota_five_hour_reset_valid = five_hour_reset_valid;
        s_monitor_data.quota_seven_day_reset_valid = seven_day_reset_valid;
        s_monitor_data.quota_five_hour_basis_points =
            read_u32_le(&packet[BLE_PAGE_PAYLOAD_OFFSET + 1]);
        s_monitor_data.quota_seven_day_basis_points =
            read_u32_le(&packet[BLE_PAGE_PAYLOAD_OFFSET + 5]);
        s_monitor_data.quota_five_hour_reset_seconds =
            read_u32_le(&packet[BLE_PAGE_PAYLOAD_OFFSET + 9]);
        s_monitor_data.quota_seven_day_reset_seconds =
            read_u32_le(&packet[BLE_PAGE_PAYLOAD_OFFSET + 13]);
        s_monitor_data.page_updated_us[2] = received_us;
        break;
    }
    case BLE_MESSAGE_DEVICE:
        changed = changed || s_monitor_data.page_updated_us[3] == 0;
        s_monitor_data.page_updated_us[3] = received_us;
        break;
    default:
        portEXIT_CRITICAL(&s_state_lock);
        return BLE_ATT_ERR_UNLIKELY;
    }

    if (changed) {
        ++s_monitor_data.revision;
    }
    portEXIT_CRITICAL(&s_state_lock);
    if (battery_interval_changed) {
        ESP_LOGI(
            kTag,
            "电量采样间隔已更新：%lu 秒",
            (unsigned long)battery_sample_interval_seconds);
    }
    return 0;
}

static void mark_mac_offline(void)
{
    portENTER_CRITICAL(&s_state_lock);
    if (s_monitor_data.mac_online) {
        s_monitor_data.mac_online = false;
        ++s_monitor_data.revision;
    }
    portEXIT_CRITICAL(&s_state_lock);
}

const char *ble_link_state_name(ble_link_state_t state)
{
    switch (state) {
    case BLE_LINK_STATE_STARTING:
        return "starting";
    case BLE_LINK_STATE_UNPAIRED:
        return "unpaired";
    case BLE_LINK_STATE_ADVERTISING:
        return "advertising";
    case BLE_LINK_STATE_PAIRING:
        return "pairing";
    case BLE_LINK_STATE_SECURING:
        return "securing";
    case BLE_LINK_STATE_CONNECTED:
        return "connected";
    case BLE_LINK_STATE_READY:
        return "ready";
    case BLE_LINK_STATE_ERROR:
        return "error";
    }
    return "unknown";
}

static int bonded_peers(ble_addr_t peers[BLE_MAX_BONDS], int *count)
{
    *count = 0;
    return ble_store_util_bonded_peers(peers, count, BLE_MAX_BONDS);
}

static bool has_stored_bond(void)
{
    ble_addr_t peers[BLE_MAX_BONDS];
    int count = 0;
    return bonded_peers(peers, &count) == 0 && count > 0;
}

static bool is_bonded_peer(const struct ble_gap_conn_desc *description)
{
    ble_addr_t peers[BLE_MAX_BONDS];
    int count = 0;
    if (bonded_peers(peers, &count) != 0) {
        return false;
    }
    for (int index = 0; index < count; ++index) {
        if (ble_addr_cmp(&peers[index], &description->peer_id_addr) == 0
            || ble_addr_cmp(&peers[index], &description->peer_ota_addr) == 0) {
            return true;
        }
    }
    return false;
}

static bool connection_is_bonded_and_encrypted(uint16_t conn_handle)
{
    struct ble_gap_conn_desc description;
    if (ble_gap_conn_find(conn_handle, &description) != 0) {
        return false;
    }
    return description.sec_state.encrypted
        && (description.sec_state.bonded || is_bonded_peer(&description));
}

static int append_status_payload(struct os_mbuf *output)
{
    const ble_link_snapshot_t snapshot = ble_link_snapshot();
    const firmware_update_snapshot_t update = firmware_update_snapshot();
    const night_sleep_snapshot_t sleep = night_sleep_snapshot();
    uint8_t flags = 0;
    if (snapshot.connected) {
        flags |= 0x01;
    }
    if (snapshot.handshake_ready) {
        flags |= 0x02;
    }
    if (snapshot.encrypted) {
        flags |= 0x04;
    }
    if (snapshot.bonded) {
        flags |= 0x08;
    }
    if (snapshot.pairing_window_open) {
        flags |= 0x10;
    }
    uint8_t payload[BLE_STATUS_PAYLOAD_LENGTH] = {
        'T',
        'R',
        'M',
        BLE_PROTOCOL_VERSION,
        MONITOR_FIRMWARE_VERSION_MAJOR,
        MONITOR_FIRMWARE_VERSION_MINOR,
        MONITOR_FIRMWARE_VERSION_PATCH,
        flags,
        snapshot.current_page,
        FIRMWARE_UPDATE_PROTOCOL_VERSION,
        (uint8_t)update.state,
        (uint8_t)update.error,
        0,
        0,
        0,
        0,
    };
    payload[12] = (uint8_t)update.received_bytes;
    payload[13] = (uint8_t)(update.received_bytes >> 8);
    payload[14] = (uint8_t)(update.received_bytes >> 16);
    payload[15] = (uint8_t)(update.received_bytes >> 24);
    payload[16] = (sleep.enabled ? 0x01 : 0x00)
        | (sleep.clock_synchronized ? 0x02 : 0x00)
        | (sleep.manual_override ? 0x04 : 0x00)
        | (((uint8_t)sleep.last_wakeup_reason & 0x07U) << 3U)
        | (sleep.rtc_wake_fallback ? 0x40 : 0x00)
        | (sleep.boot_sequence_parity ? 0x80 : 0x00);
    const uint32_t packed_schedule = (uint32_t)sleep.start_minute
        | ((uint32_t)sleep.end_minute << 11U);
    payload[17] = (uint8_t)packed_schedule;
    payload[18] = (uint8_t)(packed_schedule >> 8U);
    payload[19] = (uint8_t)(packed_schedule >> 16U);
    return os_mbuf_append(output, payload, sizeof(payload));
}

static bool packet_has_magic(const uint8_t *packet, const char *magic)
{
    return packet[0] == (uint8_t)magic[0]
        && packet[1] == (uint8_t)magic[1]
        && packet[2] == (uint8_t)magic[2];
}

static int firmware_update_result(esp_err_t result)
{
    if (result == ESP_OK) {
        return 0;
    }
    if (s_status_value_handle != 0) {
        ble_gatts_chr_updated(s_status_value_handle);
    }
    return BLE_ATT_ERR_UNLIKELY;
}

static int gatt_access(
    uint16_t conn_handle,
    uint16_t attr_handle,
    struct ble_gatt_access_ctxt *context,
    void *argument)
{
    (void)argument;

    if (context->op == BLE_GATT_ACCESS_OP_READ_CHR && attr_handle == s_status_value_handle) {
        return append_status_payload(context->om) == 0
            ? 0
            : BLE_ATT_ERR_INSUFFICIENT_RES;
    }

    if (context->op == BLE_GATT_ACCESS_OP_WRITE_CHR
        && ble_uuid_cmp(context->chr->uuid, &kFirmwareDataCharacteristicUuid.u) == 0) {
        if (!connection_is_bonded_and_encrypted(conn_handle)) {
            ESP_LOGW(kTag, "firmware data rejected: current peer is not bonded and encrypted");
            return BLE_ATT_ERR_INSUFFICIENT_AUTHEN;
        }

        const uint16_t packet_length = OS_MBUF_PKTLEN(context->om);
        if (packet_length == 0 || packet_length > BLE_FIRMWARE_DATA_MAX_LENGTH) {
            return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
        }
        uint8_t packet[BLE_FIRMWARE_DATA_MAX_LENGTH];
        uint16_t length = 0;
        const int flatten_result = ble_hs_mbuf_to_flat(
            context->om,
            packet,
            sizeof(packet),
            &length);
        if (flatten_result != 0 || length != packet_length) {
            return BLE_ATT_ERR_UNLIKELY;
        }
        return firmware_update_result(firmware_update_write(packet, length));
    }

    if (context->op == BLE_GATT_ACCESS_OP_WRITE_CHR
        && ble_uuid_cmp(context->chr->uuid, &kCommandCharacteristicUuid.u) == 0) {
        const ble_link_snapshot_t snapshot = ble_link_snapshot();
        if (!connection_is_bonded_and_encrypted(conn_handle)) {
            ESP_LOGW(kTag, "secure write rejected: current peer is not bonded and encrypted");
            return BLE_ATT_ERR_INSUFFICIENT_AUTHEN;
        }

        uint8_t packet[64] = {0};
        uint16_t length = 0;
        const uint16_t packet_length = OS_MBUF_PKTLEN(context->om);
        if (packet_length < BLE_PACKET_HEADER_LENGTH || packet_length > sizeof(packet)) {
            return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
        }
        const int result = ble_hs_mbuf_to_flat(context->om, packet, sizeof(packet), &length);
        if (result != 0 || length != packet_length) {
            return BLE_ATT_ERR_UNLIKELY;
        }
        if (packet_has_magic(packet, "TRU")) {
            if (packet[3] != FIRMWARE_UPDATE_PROTOCOL_VERSION) {
                ESP_LOGW(kTag,
                         "firmware update rejected: protocol=%u",
                         (unsigned int)packet[3]);
                return BLE_ATT_ERR_UNLIKELY;
            }
            esp_err_t update_result;
            switch (packet[4]) {
            case BLE_FIRMWARE_UPDATE_COMMAND_START:
                if (packet_length != BLE_FIRMWARE_UPDATE_START_PACKET_LENGTH) {
                    return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
                }
                update_result = firmware_update_start(
                    read_u32_le(&packet[5]),
                    packet[9],
                    packet[10],
                    packet[11],
                    &packet[12]);
                if (s_status_value_handle != 0) {
                    ble_gatts_chr_updated(s_status_value_handle);
                }
                return firmware_update_result(update_result);
            case BLE_FIRMWARE_UPDATE_COMMAND_FINISH:
                if (packet_length != BLE_FIRMWARE_UPDATE_COMMAND_PACKET_LENGTH) {
                    return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
                }
                update_result = firmware_update_finish();
                if (s_status_value_handle != 0) {
                    ble_gatts_chr_updated(s_status_value_handle);
                }
                return firmware_update_result(update_result);
            case BLE_FIRMWARE_UPDATE_COMMAND_ABORT:
                if (packet_length != BLE_FIRMWARE_UPDATE_COMMAND_PACKET_LENGTH) {
                    return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
                }
                firmware_update_abort(FIRMWARE_UPDATE_ERROR_INVALID_STATE);
                if (s_status_value_handle != 0) {
                    ble_gatts_chr_updated(s_status_value_handle);
                }
                return 0;
            default:
                return BLE_ATT_ERR_UNLIKELY;
            }
        }

        if (!packet_has_magic(packet, "TRM") || packet[3] != BLE_PROTOCOL_VERSION) {
            ESP_LOGW(kTag, "secure write rejected: protocol=%u", (unsigned int)packet[3]);
            return BLE_ATT_ERR_UNLIKELY;
        }

        if (packet[4] == BLE_MESSAGE_HELLO) {
            if (packet_length != BLE_HELLO_PACKET_LENGTH) {
                return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
            }
            set_pairing_deadline(0);
            set_state(BLE_LINK_STATE_READY, true, true, true, true, false, 0);
            ble_gatts_chr_updated(s_status_value_handle);
            ESP_LOGI(kTag,
                     "secure handshake ready: conn_handle=%u protocol=%u firmware=%s",
                     (unsigned int)conn_handle,
                     (unsigned int)BLE_PROTOCOL_VERSION,
                     MONITOR_FIRMWARE_VERSION_STRING);
            return 0;
        }

        if (!snapshot.handshake_ready) {
            ESP_LOGW(kTag, "monitor data rejected: handshake is not ready");
            return BLE_ATT_ERR_INSUFFICIENT_AUTHEN;
        }
        if (firmware_update_is_active()) {
            ESP_LOGW(kTag, "monitor data rejected: firmware update is active");
            return BLE_ATT_ERR_UNLIKELY;
        }
        if (packet[4] == BLE_MESSAGE_POWER_SCHEDULE) {
            if (packet_length != BLE_POWER_SCHEDULE_PACKET_LENGTH) {
                return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
            }
            if ((packet[5] & 0xFEU) != 0) {
                return BLE_ATT_ERR_VALUE_NOT_ALLOWED;
            }
            const esp_err_t sleep_result = night_sleep_apply_schedule(
                (packet[5] & 0x01U) != 0,
                read_u16_le(&packet[6]),
                read_u16_le(&packet[8]),
                read_u16_le(&packet[10]),
                packet[12],
                packet[13],
                packet[14],
                packet[15],
                packet[16],
                packet[17]);
            if (sleep_result == ESP_ERR_INVALID_ARG) {
                return BLE_ATT_ERR_VALUE_NOT_ALLOWED;
            }
            if (sleep_result != ESP_OK) {
                return BLE_ATT_ERR_UNLIKELY;
            }
            ble_gatts_chr_updated(s_status_value_handle);
            return 0;
        }
        const int packet_result = apply_monitor_packet(packet, packet_length);
        if (packet_result == 0) {
            ESP_LOGI(kTag,
                     "monitor data received: type=0x%02x length=%u revision=%lu",
                     (unsigned int)packet[4],
                     (unsigned int)packet_length,
                     (unsigned long)ble_link_monitor_data().revision);
            monitor_events_notify();
        }
        return packet_result;
    }

    return BLE_ATT_ERR_UNLIKELY;
}

static const struct ble_gatt_chr_def kCharacteristics[] = {
    {
        .uuid = &kCommandCharacteristicUuid.u,
        .access_cb = gatt_access,
        .flags = BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_WRITE_ENC,
    },
    {
        .uuid = &kStatusCharacteristicUuid.u,
        .access_cb = gatt_access,
        .flags = BLE_GATT_CHR_F_READ
            | BLE_GATT_CHR_F_READ_ENC
            | BLE_GATT_CHR_F_NOTIFY
            | BLE_GATT_CHR_F_NOTIFY_INDICATE_ENC,
        .val_handle = &s_status_value_handle,
    },
    {
        .uuid = &kFirmwareDataCharacteristicUuid.u,
        .access_cb = gatt_access,
        .flags = BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_WRITE_ENC,
    },
    {0},
};

static const struct ble_gatt_svc_def kServices[] = {
    {
        .type = BLE_GATT_SVC_TYPE_PRIMARY,
        .uuid = &kServiceUuid.u,
        .characteristics = kCharacteristics,
    },
    {0},
};

static int gap_event(struct ble_gap_event *event, void *argument);

static const char *advertising_phase_name(ble_adv_phase_t phase)
{
    switch (phase) {
    case BLE_ADV_PHASE_PAIRING:
        return "pairing_fast";
    case BLE_ADV_PHASE_FAST:
        return "reconnect_fast";
    case BLE_ADV_PHASE_SLOW:
        return "reconnect_slow";
    case BLE_ADV_PHASE_NONE:
        return "none";
    }
    return "unknown";
}

static void advertise_phase(ble_adv_phase_t phase)
{
    const bool paired = has_stored_bond();
    const bool pairing = pairing_window_is_open();
    if (!paired && !pairing) {
        set_state(BLE_LINK_STATE_UNPAIRED, false, false, false, false, false, 0);
        s_adv_phase = BLE_ADV_PHASE_NONE;
        ESP_LOGI(kTag, "not advertising: hold KEY to open pairing window");
        return;
    }

    struct ble_hs_adv_fields fields;
    memset(&fields, 0, sizeof(fields));
    fields.flags = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;
    fields.uuids128 = (ble_uuid128_t *)&kServiceUuid;
    fields.num_uuids128 = 1;
    fields.uuids128_is_complete = 1;

    int result = ble_gap_adv_set_fields(&fields);
    if (result != 0) {
        ESP_LOGE(kTag, "advertisement data failed: rc=%d", result);
        set_state(BLE_LINK_STATE_ERROR, false, false, false, paired, pairing, result);
        return;
    }

    struct ble_hs_adv_fields response_fields;
    memset(&response_fields, 0, sizeof(response_fields));
    response_fields.name = (uint8_t *)kDeviceName;
    response_fields.name_len = strlen(kDeviceName);
    response_fields.name_is_complete = 1;
    result = ble_gap_adv_rsp_set_fields(&response_fields);
    if (result != 0) {
        ESP_LOGE(kTag, "scan response data failed: rc=%d", result);
        set_state(BLE_LINK_STATE_ERROR, false, false, false, paired, pairing, result);
        return;
    }

    struct ble_gap_adv_params parameters;
    memset(&parameters, 0, sizeof(parameters));
    parameters.conn_mode = BLE_GAP_CONN_MODE_UND;
    parameters.disc_mode = BLE_GAP_DISC_MODE_GEN;
    const uint16_t interval = phase == BLE_ADV_PHASE_SLOW
        ? BLE_ADV_SLOW_INTERVAL_UNITS
        : BLE_ADV_FAST_INTERVAL_UNITS;
    parameters.itvl_min = interval;
    parameters.itvl_max = interval;
    const int32_t duration = phase == BLE_ADV_PHASE_FAST
        ? BLE_ADV_FAST_DURATION_MILLISECONDS
        : BLE_HS_FOREVER;
    s_adv_phase = phase;
    result = ble_gap_adv_start(
        s_own_addr_type,
        NULL,
        duration,
        &parameters,
        gap_event,
        NULL);
    if (result != 0) {
        s_adv_phase = BLE_ADV_PHASE_NONE;
        ESP_LOGE(kTag, "advertising start failed: rc=%d", result);
        set_state(BLE_LINK_STATE_ERROR, false, false, false, paired, pairing, result);
        return;
    }

    set_state(
        pairing ? BLE_LINK_STATE_PAIRING : BLE_LINK_STATE_ADVERTISING,
        false,
        false,
        false,
        paired,
        pairing,
        0);
    ESP_LOGI(kTag,
             "advertising: name=%s protocol=%u paired=%u pairing_window=%u phase=%s interval_units=%u",
             kDeviceName,
             BLE_PROTOCOL_VERSION,
             paired ? 1U : 0U,
             pairing ? 1U : 0U,
             advertising_phase_name(phase),
             (unsigned int)interval);
}

static void advertise(void)
{
    if (pairing_window_is_open()) {
        advertise_phase(BLE_ADV_PHASE_PAIRING);
        return;
    }
    advertise_phase(BLE_ADV_PHASE_FAST);
}

static int gap_event(struct ble_gap_event *event, void *argument)
{
    (void)argument;
    switch (event->type) {
    case BLE_GAP_EVENT_CONNECT: {
        if (event->connect.status != 0) {
            ESP_LOGW(kTag, "connection failed: status=%d", event->connect.status);
            advertise();
            return 0;
        }

        struct ble_gap_conn_desc description;
        int result = ble_gap_conn_find(event->connect.conn_handle, &description);
        if (result != 0) {
            ESP_LOGE(kTag, "connection description failed: rc=%d", result);
            ble_gap_terminate(event->connect.conn_handle, BLE_ERR_REM_USER_CONN_TERM);
            return 0;
        }

        const bool known_peer = is_bonded_peer(&description);
        const bool pairing = pairing_window_is_open();
        if (!known_peer && !pairing) {
            ESP_LOGW(kTag, "rejecting unpaired connection outside pairing window");
            ble_gap_terminate(event->connect.conn_handle, BLE_ERR_REM_USER_CONN_TERM);
            return 0;
        }

        set_connection_handle(event->connect.conn_handle);
        s_adv_phase = BLE_ADV_PHASE_NONE;
        set_state(BLE_LINK_STATE_SECURING, true, false, false, known_peer, pairing, 0);
        ESP_LOGI(kTag,
                 "connected; securing: conn_handle=%u known_peer=%u pairing_window=%u interval_us=%u latency=%u supervision_ms=%u",
                 (unsigned int)event->connect.conn_handle,
                 known_peer ? 1U : 0U,
                 pairing ? 1U : 0U,
                 (unsigned int)description.conn_itvl * 1250U,
                 (unsigned int)description.conn_latency,
                 (unsigned int)description.supervision_timeout * 10U);

        result = ble_gap_security_initiate(event->connect.conn_handle);
        if (result != 0 && result != BLE_HS_EALREADY) {
            ESP_LOGE(kTag, "security initiation failed: rc=%d", result);
            ble_gap_terminate(event->connect.conn_handle, BLE_ERR_REM_USER_CONN_TERM);
        }
        return 0;
    }
    case BLE_GAP_EVENT_ENC_CHANGE: {
        struct ble_gap_conn_desc description;
        const int find_result = ble_gap_conn_find(event->enc_change.conn_handle, &description);
        if (event->enc_change.status != 0 || find_result != 0 || !description.sec_state.encrypted) {
            ESP_LOGW(kTag,
                     "encryption failed: status=%d find_rc=%d",
                     event->enc_change.status,
                     find_result);
            ble_gap_terminate(event->enc_change.conn_handle, BLE_ERR_REM_USER_CONN_TERM);
            return 0;
        }

        const bool paired = description.sec_state.bonded || is_bonded_peer(&description);
        const bool pairing = pairing_window_is_open();
        if (!paired && !pairing) {
            ESP_LOGW(kTag, "encrypted connection has no accepted bond");
            ble_gap_terminate(event->enc_change.conn_handle, BLE_ERR_REM_USER_CONN_TERM);
            return 0;
        }

        set_state(BLE_LINK_STATE_CONNECTED, true, false, true, paired, pairing, 0);
        ESP_LOGI(kTag,
                 "link encrypted: conn_handle=%u bonded=%u pairing_window=%u",
                 (unsigned int)event->enc_change.conn_handle,
                 paired ? 1U : 0U,
                 pairing ? 1U : 0U);
        if (paired && s_gatt_schema_change_pending) {
            notify_gatt_schema_changed();
        }
        return 0;
    }
    case BLE_GAP_EVENT_IDENTITY_RESOLVED: {
        const ble_link_snapshot_t snapshot = ble_link_snapshot();
        const bool paired = has_stored_bond();
        set_state(
            snapshot.state,
            snapshot.connected,
            snapshot.handshake_ready,
            snapshot.encrypted,
            paired,
            snapshot.pairing_window_open,
            snapshot.last_error);
        return 0;
    }
    case BLE_GAP_EVENT_REPEAT_PAIRING: {
        if (!pairing_window_is_open()) {
            ESP_LOGW(kTag, "repeat pairing ignored outside pairing window");
            return BLE_GAP_REPEAT_PAIRING_IGNORE;
        }
        struct ble_gap_conn_desc description;
        const int result = ble_gap_conn_find(event->repeat_pairing.conn_handle, &description);
        if (result != 0) {
            ESP_LOGE(kTag, "repeat pairing connection lookup failed: rc=%d", result);
            return BLE_GAP_REPEAT_PAIRING_IGNORE;
        }
        const int delete_result = ble_store_util_delete_peer(&description.peer_id_addr);
        if (delete_result != 0) {
            ESP_LOGE(kTag, "repeat pairing bond removal failed: rc=%d", delete_result);
            return BLE_GAP_REPEAT_PAIRING_IGNORE;
        }
        ESP_LOGI(kTag, "repeat pairing accepted inside pairing window");
        return BLE_GAP_REPEAT_PAIRING_RETRY;
    }
    case BLE_GAP_EVENT_DISCONNECT:
        ESP_LOGI(kTag, "disconnected: reason=%d", event->disconnect.reason);
        firmware_update_abort(FIRMWARE_UPDATE_ERROR_DISCONNECTED);
        set_connection_handle(BLE_HS_CONN_HANDLE_NONE);
        s_adv_phase = BLE_ADV_PHASE_NONE;
        mark_mac_offline();
        advertise();
        return 0;
    case BLE_GAP_EVENT_ADV_COMPLETE:
        ESP_LOGI(kTag, "advertising completed: reason=%d", event->adv_complete.reason);
        if (s_adv_phase == BLE_ADV_PHASE_FAST
            && has_stored_bond()
            && !pairing_window_is_open()) {
            advertise_phase(BLE_ADV_PHASE_SLOW);
        } else {
            advertise();
        }
        return 0;
    case BLE_GAP_EVENT_CONN_UPDATE: {
        struct ble_gap_conn_desc description;
        const int result = ble_gap_conn_find(event->conn_update.conn_handle, &description);
        if (result == 0) {
            ESP_LOGI(kTag,
                     "connection parameters updated: interval_us=%u latency=%u supervision_ms=%u",
                     (unsigned int)description.conn_itvl * 1250U,
                     (unsigned int)description.conn_latency,
                     (unsigned int)description.supervision_timeout * 10U);
        } else {
            ESP_LOGW(kTag, "connection parameter lookup failed: rc=%d", result);
        }
        return 0;
    }
    case BLE_GAP_EVENT_SUBSCRIBE:
        ESP_LOGI(kTag,
                 "subscription: conn_handle=%u attr_handle=%u reason=%u notify=%u indicate=%u",
                 (unsigned int)event->subscribe.conn_handle,
                 (unsigned int)event->subscribe.attr_handle,
                 (unsigned int)event->subscribe.reason,
                 (unsigned int)event->subscribe.cur_notify,
                 (unsigned int)event->subscribe.cur_indicate);
        if (s_gatt_schema_change_pending
            && s_gatt_service_changed_handle != 0
            && event->subscribe.attr_handle == s_gatt_service_changed_handle
            && event->subscribe.cur_indicate) {
            notify_gatt_schema_changed();
        }
        return 0;
    case BLE_GAP_EVENT_NOTIFY_TX:
        if (s_gatt_schema_change_pending
            && s_gatt_service_changed_handle != 0
            && event->notify_tx.attr_handle == s_gatt_service_changed_handle
            && event->notify_tx.indication
            && event->notify_tx.status == BLE_HS_EDONE) {
            persist_gatt_schema_version();
        }
        return 0;
    case BLE_GAP_EVENT_MTU:
        ESP_LOGI(kTag,
                 "mtu updated: conn_handle=%u mtu=%u",
                 (unsigned int)event->mtu.conn_handle,
                 (unsigned int)event->mtu.value);
        return 0;
    default:
        return 0;
    }
}

static void on_reset(int reason)
{
    ESP_LOGE(kTag, "NimBLE reset: reason=%d", reason);
    set_host_synced(false);
    set_connection_handle(BLE_HS_CONN_HANDLE_NONE);
    set_state(BLE_LINK_STATE_ERROR, false, false, false, has_stored_bond(), false, reason);
}

static void on_sync(void)
{
    int result = ble_hs_util_ensure_addr(0);
    if (result != 0) {
        ESP_LOGE(kTag, "BLE identity address failed: rc=%d", result);
        set_state(BLE_LINK_STATE_ERROR, false, false, false, has_stored_bond(), false, result);
        return;
    }
    result = ble_hs_id_infer_auto(0, &s_own_addr_type);
    if (result != 0) {
        ESP_LOGE(kTag, "BLE address type failed: rc=%d", result);
        set_state(BLE_LINK_STATE_ERROR, false, false, false, has_stored_bond(), false, result);
        return;
    }
    set_host_synced(true);
    resolve_gatt_service_changed_handle();
    notify_gatt_schema_changed();
    advertise();
}

static void host_task(void *parameter)
{
    (void)parameter;
    ESP_LOGI(kTag, "NimBLE host started");
    nimble_port_run();
    nimble_port_freertos_deinit();
}

esp_err_t ble_link_start(void)
{
    set_state(BLE_LINK_STATE_STARTING, false, false, false, false, false, 0);

    esp_err_t result = nvs_flash_init();
    if (result == ESP_ERR_NVS_NO_FREE_PAGES || result == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        result = nvs_flash_erase();
        if (result == ESP_OK) {
            result = nvs_flash_init();
        }
    }
    if (result != ESP_OK) {
        set_state(BLE_LINK_STATE_ERROR, false, false, false, false, false, result);
        return result;
    }
    load_gatt_schema_state();

    const esp_err_t sleep_result = night_sleep_initialize();
    if (sleep_result != ESP_OK) {
        ESP_LOGW(kTag,
                 "night sleep initialization incomplete: %s",
                 esp_err_to_name(sleep_result));
    }

    result = nimble_port_init();
    if (result != ESP_OK) {
        set_state(BLE_LINK_STATE_ERROR, false, false, false, false, false, result);
        return result;
    }

    ble_hs_cfg.reset_cb = on_reset;
    ble_hs_cfg.sync_cb = on_sync;
    ble_hs_cfg.store_status_cb = ble_store_util_status_rr;
    ble_hs_cfg.sm_io_cap = BLE_SM_IO_CAP_NO_IO;
    ble_hs_cfg.sm_bonding = 1;
    ble_hs_cfg.sm_mitm = 0;
    ble_hs_cfg.sm_sc = 1;
    ble_hs_cfg.sm_our_key_dist = BLE_SM_PAIR_KEY_DIST_ENC | BLE_SM_PAIR_KEY_DIST_ID;
    ble_hs_cfg.sm_their_key_dist = BLE_SM_PAIR_KEY_DIST_ENC | BLE_SM_PAIR_KEY_DIST_ID;

    ble_svc_gap_init();
    ble_svc_gatt_init();

    int host_result = ble_gatts_count_cfg(kServices);
    if (host_result == 0) {
        host_result = ble_gatts_add_svcs(kServices);
    }
    if (host_result == 0) {
        host_result = ble_svc_gap_device_name_set(kDeviceName);
    }
    if (host_result != 0) {
        ESP_LOGE(kTag, "GATT initialization failed: rc=%d", host_result);
        set_state(BLE_LINK_STATE_ERROR, false, false, false, false, false, host_result);
        return ESP_FAIL;
    }

    ble_store_config_init();
    nimble_port_freertos_init(host_task);
    return ESP_OK;
}

esp_err_t ble_link_set_current_page(uint8_t page)
{
    if (page >= BLE_LINK_PAGE_COUNT) {
        return ESP_ERR_INVALID_ARG;
    }

    bool changed;
    portENTER_CRITICAL(&s_state_lock);
    changed = s_snapshot.current_page != page;
    s_snapshot.current_page = page;
    portEXIT_CRITICAL(&s_state_lock);

    if (changed && s_status_value_handle != 0) {
        ble_gatts_chr_updated(s_status_value_handle);
    }
    if (changed) {
        monitor_events_notify();
    }
    return ESP_OK;
}

esp_err_t ble_link_open_pairing_window(uint32_t duration_seconds)
{
    if (duration_seconds == 0 || duration_seconds > 300) {
        return ESP_ERR_INVALID_ARG;
    }
    if (firmware_update_is_active()) {
        return ESP_ERR_INVALID_STATE;
    }

    const bool paired = has_stored_bond();
    set_pairing_deadline(esp_timer_get_time() + ((int64_t)duration_seconds * 1000000));
    set_state(BLE_LINK_STATE_PAIRING, false, false, false, paired, true, 0);
    ESP_LOGI(kTag,
             "pairing window opened: duration=%lu s bonded=%u",
             (unsigned long)duration_seconds,
             paired ? 1U : 0U);

    const uint16_t conn_handle = connection_handle();
    if (conn_handle != BLE_HS_CONN_HANDLE_NONE) {
        const int result = ble_gap_terminate(conn_handle, BLE_ERR_REM_USER_CONN_TERM);
        return result == 0 ? ESP_OK : ESP_FAIL;
    }
    if (!host_is_synced()) {
        return ESP_OK;
    }
    if (ble_gap_adv_active()) {
        const int result = ble_gap_adv_stop();
        return result == 0 ? ESP_OK : ESP_FAIL;
    }
    advertise();
    return ESP_OK;
}

void ble_link_tick(void)
{
    firmware_update_tick();
    const int64_t now_us = esp_timer_get_time();
    bool offline_expired = false;
    portENTER_CRITICAL(&s_state_lock);
    if (s_monitor_data.mac_online
        && s_monitor_data.offline_timeout_seconds > 0
        && s_monitor_data.last_signal_us > 0
        && now_us - s_monitor_data.last_signal_us
            > (int64_t)s_monitor_data.offline_timeout_seconds * 1000000) {
        s_monitor_data.mac_online = false;
        ++s_monitor_data.revision;
        offline_expired = true;
    }
    portEXIT_CRITICAL(&s_state_lock);
    if (offline_expired) {
        ESP_LOGW(kTag, "Mac signal timeout expired");
        monitor_events_notify();
    }

    const ble_link_snapshot_t snapshot = ble_link_snapshot();
    if (!snapshot.pairing_window_open || pairing_window_is_open()) {
        return;
    }

    set_pairing_deadline(0);
    const bool paired = has_stored_bond();
    ESP_LOGI(kTag, "pairing window closed: paired=%u", paired ? 1U : 0U);

    const uint16_t conn_handle = connection_handle();
    if (conn_handle != BLE_HS_CONN_HANDLE_NONE) {
        if (!paired) {
            ble_gap_terminate(conn_handle, BLE_ERR_REM_USER_CONN_TERM);
            return;
        }
        set_state(
            snapshot.state,
            snapshot.connected,
            snapshot.handshake_ready,
            snapshot.encrypted,
            true,
            false,
            snapshot.last_error);
        return;
    }
    if (ble_gap_adv_active()) {
        const int result = ble_gap_adv_stop();
        if (result != 0) {
            ESP_LOGW(kTag, "pairing advertising stop failed: rc=%d", result);
        }
        return;
    }

    s_adv_phase = BLE_ADV_PHASE_NONE;
    if (paired) {
        advertise();
        return;
    }
    set_state(
        BLE_LINK_STATE_UNPAIRED,
        false,
        false,
        false,
        false,
        false,
        0);
}
