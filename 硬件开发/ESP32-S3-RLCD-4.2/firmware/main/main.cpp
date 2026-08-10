#include <cstdint>
#include <cstdio>

#include "driver/gpio.h"
#include "esp_attr.h"
#include "esp_heap_caps.h"
#include "esp_intr_alloc.h"
#include "esp_log.h"
#include "esp_sleep.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "battery_monitor.h"
#include "board_config.h"
#include "board_power.h"
#include "ble_link.h"
#include "firmware_update.h"
#include "monitor_events.h"
#include "night_sleep.h"
#include "power_manager.h"
#include "u8g2_st7305.h"

namespace {

constexpr char kTag[] = "monitor";
constexpr char kFirmwareVersion[] = MONITOR_FIRMWARE_VERSION_STRING;
constexpr int64_t kHeartbeatIntervalUs = 60'000'000;
constexpr int64_t kDebounceIntervalUs = 50'000;
constexpr int64_t kLongPressIntervalUs = 1'500'000;
constexpr uint32_t kPairingWindowSeconds = 60;
constexpr uint32_t kIdleWaitMilliseconds = 1'000;
constexpr uint32_t kFirmwareUpdateWaitMilliseconds = 50;

enum class Page : uint8_t {
    kOverview,
    kTasks,
    kQuota,
    kDevice,
    kCount,
};

u8g2_st7305_t g_display;
size_t g_psram_bytes;
uint32_t g_screen_refreshes;

const char *PageName(Page page)
{
    switch (page) {
    case Page::kOverview:
        return "overview";
    case Page::kTasks:
        return "tasks";
    case Page::kQuota:
        return "quota";
    case Page::kDevice:
        return "device";
    case Page::kCount:
        break;
    }
    return "unknown";
}

const char *PageDisplayName(Page page)
{
    switch (page) {
    case Page::kOverview:
        return "OVERVIEW";
    case Page::kTasks:
        return "TASKS";
    case Page::kQuota:
        return "QUOTA";
    case Page::kDevice:
        return "DEVICE";
    case Page::kCount:
        break;
    }
    return "UNKNOWN";
}

Page NextPage(Page page)
{
    const auto next = (static_cast<uint8_t>(page) + 1U) % static_cast<uint8_t>(Page::kCount);
    return static_cast<Page>(next);
}

void DrawTextCentered(u8g2_t *u8g2, int x, int width, int baseline, const char *text)
{
    const int text_width = static_cast<int>(u8g2_GetStrWidth(u8g2, text));
    const int text_x = x + ((width - text_width) / 2);
    u8g2_DrawStr(u8g2, text_x > x ? text_x : x, baseline, text);
}

void DrawTextRightAligned(u8g2_t *u8g2, int right, int baseline, const char *text)
{
    const int text_width = static_cast<int>(u8g2_GetStrWidth(u8g2, text));
    u8g2_DrawStr(u8g2, right - text_width, baseline, text);
}

void DrawTextCenteredWithFallback(
    u8g2_t *u8g2,
    int x,
    int width,
    int baseline,
    const char *text,
    const uint8_t *preferred_font,
    const uint8_t *fallback_font)
{
    u8g2_SetFont(u8g2, preferred_font);
    if (static_cast<int>(u8g2_GetStrWidth(u8g2, text)) > width) {
        u8g2_SetFont(u8g2, fallback_font);
    }
    DrawTextCentered(u8g2, x, width, baseline, text);
}

void DrawLabeledValue(
    u8g2_t *u8g2,
    int x,
    int width,
    int label_baseline,
    int value_baseline,
    const char *label,
    const char *value,
    const uint8_t *value_font,
    const uint8_t *fallback_font = u8g2_font_helvB14_tf)
{
    u8g2_SetFont(u8g2, u8g2_font_6x12_tf);
    DrawTextCentered(u8g2, x, width, label_baseline, label);
    DrawTextCenteredWithFallback(
        u8g2,
        x,
        width,
        value_baseline,
        value,
        value_font,
        fallback_font);
}

void FormatCompactUnsigned(uint64_t value, char *output, size_t output_size)
{
    if (value < 1'000) {
        std::snprintf(output, output_size, "%llu", static_cast<unsigned long long>(value));
        return;
    }

    struct Scale {
        uint64_t divisor;
        const char *suffix;
    };
    constexpr Scale scales[] = {
        {1'000'000'000'000ULL, "T"},
        {1'000'000'000ULL, "B"},
        {1'000'000ULL, "M"},
        {1'000ULL, "K"},
    };
    for (const Scale &scale : scales) {
        if (value < scale.divisor) {
            continue;
        }
        const uint64_t whole = value / scale.divisor;
        const uint64_t decimal = ((value % scale.divisor) * 10ULL) / scale.divisor;
        if (whole >= 100 || decimal == 0) {
            std::snprintf(output,
                          output_size,
                          "%llu%s",
                          static_cast<unsigned long long>(whole),
                          scale.suffix);
        } else {
            std::snprintf(output,
                          output_size,
                          "%llu.%llu%s",
                          static_cast<unsigned long long>(whole),
                          static_cast<unsigned long long>(decimal),
                          scale.suffix);
        }
        return;
    }
}

void FormatCost(uint64_t microdollars, char *output, size_t output_size)
{
    const uint64_t dollars = microdollars / 1'000'000ULL;
    if (dollars >= 1'000ULL) {
        char compact[16];
        FormatCompactUnsigned(dollars, compact, sizeof(compact));
        std::snprintf(output, output_size, "$%s", compact);
        return;
    }
    const uint64_t cents = ((microdollars % 1'000'000ULL) + 5'000ULL) / 10'000ULL;
    const uint64_t rounded_dollars = dollars + (cents / 100ULL);
    std::snprintf(output,
                  output_size,
                  "$%llu.%02llu",
                  static_cast<unsigned long long>(rounded_dollars),
                  static_cast<unsigned long long>(cents % 100ULL));
}

void FormatPercentage(uint32_t basis_points, char *output, size_t output_size)
{
    const uint64_t rounded_percent = (static_cast<uint64_t>(basis_points) + 50ULL) / 100ULL;
    std::snprintf(
        output,
        output_size,
        "%llu%%",
        static_cast<unsigned long long>(rounded_percent));
}

void FormatResetDuration(uint32_t seconds, char *output, size_t output_size)
{
    const uint32_t days = seconds / 86'400U;
    const uint32_t hours = (seconds % 86'400U) / 3'600U;
    const uint32_t minutes = (seconds % 3'600U) / 60U;
    std::snprintf(output,
                  output_size,
                  "%luD %luH %luM",
                  static_cast<unsigned long>(days),
                  static_cast<unsigned long>(hours),
                  static_cast<unsigned long>(minutes));
}

const char *PageDataStatus(Page page, const ble_link_monitor_data_t &data)
{
    if (data.page_updated_us[static_cast<uint8_t>(page)] <= 0) {
        return "NO DATA";
    }
    if (!data.mac_online) {
        return "OFFLINE";
    }
    return data.data_stale ? "STALE" : "SYNCED";
}

void DrawHeader(
    u8g2_t *u8g2,
    Page page,
    const ble_link_monitor_data_t &data,
    const battery_monitor::Snapshot &battery)
{
    u8g2_SetFont(u8g2, u8g2_font_helvB14_tf);
    u8g2_DrawStr(u8g2, 16, 25, PageDisplayName(page));

    char battery_text[16];
    switch (battery.state) {
    case battery_monitor::State::kAvailable:
        std::snprintf(
            battery_text,
            sizeof(battery_text),
            "BAT %u%%",
            static_cast<unsigned int>(battery.percentage));
        break;
    case battery_monitor::State::kNotPresent:
        std::snprintf(battery_text, sizeof(battery_text), "BAT NONE");
        break;
    case battery_monitor::State::kUnavailable:
        std::snprintf(battery_text, sizeof(battery_text), "BAT N/A");
        break;
    }

    u8g2_SetFont(u8g2, u8g2_font_5x8_tf);
    const int battery_width = static_cast<int>(u8g2_GetStrWidth(u8g2, battery_text));
    const int battery_x = board::kDisplayWidth - 16 - battery_width;
    u8g2_DrawStr(u8g2, battery_x, 22, battery_text);

    if (page != Page::kDevice) {
        char page_text[16];
        std::snprintf(page_text,
                      sizeof(page_text),
                      "%s",
                      PageDataStatus(page, data));
        const int page_width = static_cast<int>(u8g2_GetStrWidth(u8g2, page_text));
        u8g2_DrawStr(u8g2, battery_x - 12 - page_width, 22, page_text);
    }
}

const char *BleFooterStatus(const ble_link_snapshot_t &link)
{
    switch (link.state) {
    case BLE_LINK_STATE_STARTING:
        return "STARTING";
    case BLE_LINK_STATE_UNPAIRED:
        return "HOLD KEY TO PAIR";
    case BLE_LINK_STATE_ADVERTISING:
        return "WAITING FOR MAC";
    case BLE_LINK_STATE_PAIRING:
        return "PAIRING OPEN";
    case BLE_LINK_STATE_SECURING:
        return "SECURING";
    case BLE_LINK_STATE_CONNECTED:
        return "HANDSHAKING";
    case BLE_LINK_STATE_READY:
        return "";
    case BLE_LINK_STATE_ERROR:
        return "BLE ERROR";
    }
    return "BLE UNKNOWN";
}

const char *MacConnectionStatus(
    const ble_link_snapshot_t &link,
    const ble_link_monitor_data_t &data)
{
    if (link.handshake_ready && data.mac_online) {
        return "CONNECTED";
    }
    if (link.handshake_ready) {
        return data.last_signal_us > 0 ? "OFFLINE" : "WAITING DATA";
    }
    if (link.pairing_window_open && !link.connected) {
        return "PAIRING OPEN";
    }
    if (link.state == BLE_LINK_STATE_UNPAIRED) {
        return "NOT PAIRED";
    }
    if (link.connected) {
        return link.encrypted ? "HANDSHAKING" : "SECURING";
    }
    return "NOT CONNECTED";
}

const char *NetworkStatus(const ble_link_monitor_data_t &data)
{
    if (!data.mac_online) {
        return "UNKNOWN";
    }
    return data.network_online ? "ONLINE" : "OFFLINE";
}

const char *TokenRouterStatus(const ble_link_monitor_data_t &data)
{
    if (!data.mac_online || !data.network_online) {
        return "UNKNOWN";
    }
    if (!data.tokenrouter_online) {
        return "OFFLINE";
    }
    return data.data_stale ? "STALE" : "ONLINE";
}

const char *BleSecurityStatus(const ble_link_snapshot_t &link)
{
    if (link.handshake_ready && link.encrypted && link.bonded) {
        return "SECURE + BONDED";
    }
    if (link.pairing_window_open) {
        return "PAIRING OPEN";
    }
    if (link.connected && link.encrypted) {
        return "SECURE";
    }
    return BleFooterStatus(link);
}

void DrawFooter(u8g2_t *u8g2, const ble_link_snapshot_t &link)
{
    if (link.state == BLE_LINK_STATE_READY) {
        return;
    }
    u8g2_SetFont(u8g2, u8g2_font_6x12_tf);
    const char *status = BleFooterStatus(link);
    DrawTextCentered(u8g2, 16, 368, 292, status);
}

void DrawOverviewPage(
    u8g2_t *u8g2,
    const ble_link_snapshot_t &link,
    const ble_link_monitor_data_t &data)
{
    char cost_text[20];
    char request_text[20];
    char token_text[20];
    if (data.overview_valid) {
        FormatCost(data.overview_cost_microdollars, cost_text, sizeof(cost_text));
        FormatCompactUnsigned(data.overview_requests, request_text, sizeof(request_text));
        FormatCompactUnsigned(data.overview_tokens, token_text, sizeof(token_text));
    } else {
        std::snprintf(cost_text, sizeof(cost_text), "--");
        std::snprintf(request_text, sizeof(request_text), "--");
        std::snprintf(token_text, sizeof(token_text), "--");
    }

    DrawLabeledValue(
        u8g2,
        16,
        368,
        68,
        120,
        "TODAY COST",
        cost_text,
        data.overview_valid ? u8g2_font_inb30_mf : u8g2_font_helvB24_tf,
        u8g2_font_helvB24_tf);

    DrawLabeledValue(
        u8g2, 16, 178, 162, 206, "REQUESTS", request_text, u8g2_font_helvB24_tf);
    DrawLabeledValue(
        u8g2, 206, 178, 162, 206, "TOKENS", token_text, u8g2_font_helvB24_tf);

    DrawLabeledValue(
        u8g2,
        16,
        116,
        248,
        276,
        "MAC",
        MacConnectionStatus(link, data),
        u8g2_font_helvB10_tf,
        u8g2_font_6x12_tf);
    DrawLabeledValue(
        u8g2,
        142,
        116,
        248,
        276,
        "NETWORK",
        NetworkStatus(data),
        u8g2_font_helvB10_tf,
        u8g2_font_6x12_tf);
    DrawLabeledValue(
        u8g2,
        268,
        116,
        248,
        276,
        "ROUTER",
        TokenRouterStatus(data),
        u8g2_font_helvB10_tf,
        u8g2_font_6x12_tf);
}

void DrawTasksPage(u8g2_t *u8g2, const ble_link_monitor_data_t &data)
{
    const bool has_data = data.page_updated_us[1] > 0;
    char total_text[16];
    char done_text[16];
    char error_text[16];
    char stale_text[16];
    if (has_data) {
        std::snprintf(total_text, sizeof(total_text), "%u", static_cast<unsigned int>(data.tasks_total));
        std::snprintf(done_text, sizeof(done_text), "%u", static_cast<unsigned int>(data.tasks_done));
        std::snprintf(error_text, sizeof(error_text), "%u", static_cast<unsigned int>(data.tasks_error));
        std::snprintf(stale_text, sizeof(stale_text), "%u", static_cast<unsigned int>(data.tasks_stale));
    } else {
        std::snprintf(total_text, sizeof(total_text), "--");
        std::snprintf(done_text, sizeof(done_text), "--");
        std::snprintf(error_text, sizeof(error_text), "--");
        std::snprintf(stale_text, sizeof(stale_text), "--");
    }

    DrawLabeledValue(
        u8g2,
        16,
        368,
        71,
        141,
        "RECENT RESULTS",
        total_text,
        has_data ? u8g2_font_logisoso42_tn : u8g2_font_helvB24_tf,
        u8g2_font_helvB24_tf);

    DrawLabeledValue(
        u8g2,
        16,
        116,
        197,
        255,
        "DONE",
        done_text,
        u8g2_font_helvB24_tf);
    DrawLabeledValue(
        u8g2,
        142,
        116,
        197,
        255,
        "ERROR",
        error_text,
        u8g2_font_helvB24_tf);
    DrawLabeledValue(
        u8g2,
        268,
        116,
        197,
        255,
        "STALE",
        stale_text,
        u8g2_font_helvB24_tf);
}

void DrawQuotaPage(u8g2_t *u8g2, const ble_link_monitor_data_t &data)
{
    char five_hour[20];
    char seven_day[20];
    char five_hour_reset[20];
    char seven_day_reset[20];
    if (data.quota_five_hour_valid) {
        FormatPercentage(data.quota_five_hour_basis_points, five_hour, sizeof(five_hour));
    } else {
        std::snprintf(five_hour, sizeof(five_hour), "--");
    }
    if (data.quota_seven_day_valid) {
        FormatPercentage(data.quota_seven_day_basis_points, seven_day, sizeof(seven_day));
    } else {
        std::snprintf(seven_day, sizeof(seven_day), "--");
    }
    if (data.quota_five_hour_reset_valid) {
        FormatResetDuration(
            data.quota_five_hour_reset_seconds,
            five_hour_reset,
            sizeof(five_hour_reset));
    } else {
        std::snprintf(five_hour_reset, sizeof(five_hour_reset), "--");
    }
    if (data.quota_seven_day_reset_valid) {
        FormatResetDuration(
            data.quota_seven_day_reset_seconds,
            seven_day_reset,
            sizeof(seven_day_reset));
    } else {
        std::snprintf(seven_day_reset, sizeof(seven_day_reset), "--");
    }

    DrawLabeledValue(
        u8g2,
        16,
        178,
        69,
        128,
        "5H LEFT",
        five_hour,
        data.quota_five_hour_valid ? u8g2_font_inb30_mf : u8g2_font_helvB24_tf,
        u8g2_font_helvB24_tf);
    DrawLabeledValue(
        u8g2,
        206,
        178,
        69,
        128,
        "7D LEFT",
        seven_day,
        data.quota_seven_day_valid ? u8g2_font_inb30_mf : u8g2_font_helvB24_tf,
        u8g2_font_helvB24_tf);

    DrawLabeledValue(
        u8g2,
        16,
        178,
        200,
        257,
        "NEXT RESET",
        five_hour_reset,
        u8g2_font_helvB18_tf,
        u8g2_font_helvB14_tf);
    DrawLabeledValue(
        u8g2,
        206,
        178,
        200,
        257,
        "NEXT RESET",
        seven_day_reset,
        u8g2_font_helvB18_tf,
        u8g2_font_helvB14_tf);
}

void DrawDevicePage(
    u8g2_t *u8g2,
    const ble_link_snapshot_t &link,
    const ble_link_monitor_data_t &data,
    const battery_monitor::Snapshot &battery)
{
    char battery_voltage[16];
    switch (battery.state) {
    case battery_monitor::State::kAvailable: {
        const unsigned int volts = battery.voltage_millivolts / 1'000U;
        const unsigned int centivolts = (battery.voltage_millivolts % 1'000U) / 10U;
        std::snprintf(
            battery_voltage,
            sizeof(battery_voltage),
            "%u.%02uV",
            volts,
            centivolts);
        break;
    }
    case battery_monitor::State::kNotPresent:
        std::snprintf(battery_voltage, sizeof(battery_voltage), "NO BATTERY");
        break;
    case battery_monitor::State::kUnavailable:
        std::snprintf(battery_voltage, sizeof(battery_voltage), "UNAVAILABLE");
        break;
    }

    DrawTextCenteredWithFallback(
        u8g2,
        16,
        368,
        103,
        MacConnectionStatus(link, data),
        u8g2_font_helvB24_tf,
        u8g2_font_helvB18_tf);

    u8g2_SetFont(u8g2, u8g2_font_helvR12_tf);
    u8g2_DrawStr(u8g2, 24, 153, "BATTERY VOLTAGE");
    u8g2_SetFont(u8g2, u8g2_font_helvB14_tf);
    DrawTextRightAligned(u8g2, 376, 153, battery_voltage);

    u8g2_SetFont(u8g2, u8g2_font_helvR12_tf);
    u8g2_DrawStr(u8g2, 24, 191, "BLE LINK");
    u8g2_SetFont(u8g2, u8g2_font_helvB14_tf);
    DrawTextRightAligned(u8g2, 376, 191, BleSecurityStatus(link));

    u8g2_SetFont(u8g2, u8g2_font_helvR12_tf);
    u8g2_DrawStr(u8g2, 24, 229, "DATA STATE");
    u8g2_SetFont(u8g2, u8g2_font_helvB14_tf);
    DrawTextRightAligned(u8g2, 376, 229, PageDataStatus(Page::kDevice, data));

    u8g2_SetFont(u8g2, u8g2_font_helvR12_tf);
    u8g2_DrawStr(u8g2, 24, 267, "FIRMWARE");
    u8g2_SetFont(u8g2, u8g2_font_helvB14_tf);
    DrawTextRightAligned(u8g2, 376, 267, kFirmwareVersion);
}

void DrawFirmwareUpdatePage(
    u8g2_t *u8g2,
    const firmware_update_snapshot_t &update)
{
    u8g2_ClearBuffer(u8g2);
    u8g2_SetDrawColor(u8g2, 1);
    u8g2_SetFont(u8g2, u8g2_font_helvB14_tf);
    u8g2_DrawStr(u8g2, 16, 25, "FIRMWARE");

    const char *state_text = "UNKNOWN";
    switch (update.state) {
    case FIRMWARE_UPDATE_STATE_RECEIVING:
        state_text = "UPDATING";
        break;
    case FIRMWARE_UPDATE_STATE_VERIFYING:
        state_text = "VERIFYING";
        break;
    case FIRMWARE_UPDATE_STATE_RESTARTING:
        state_text = "RESTARTING";
        break;
    case FIRMWARE_UPDATE_STATE_FAILED:
        state_text = "UPDATE FAILED";
        break;
    case FIRMWARE_UPDATE_STATE_IDLE:
        state_text = "READY";
        break;
    }

    u8g2_SetFont(u8g2, u8g2_font_helvB24_tf);
    DrawTextCentered(u8g2, 16, 368, 99, state_text);

    if (update.state == FIRMWARE_UPDATE_STATE_RECEIVING) {
        char progress_text[8];
        std::snprintf(
            progress_text,
            sizeof(progress_text),
            "%u%%",
            static_cast<unsigned int>(update.progress_percent));
        u8g2_SetFont(u8g2, u8g2_font_inb30_mf);
        DrawTextCentered(u8g2, 16, 368, 184, progress_text);
    } else if (update.state == FIRMWARE_UPDATE_STATE_FAILED) {
        char error_text[24];
        std::snprintf(
            error_text,
            sizeof(error_text),
            "ERROR %u",
            static_cast<unsigned int>(update.error));
        u8g2_SetFont(u8g2, u8g2_font_helvB14_tf);
        DrawTextCentered(u8g2, 16, 368, 174, error_text);
    }

    u8g2_SetFont(u8g2, u8g2_font_6x12_tf);
    const char *detail = update.state == FIRMWARE_UPDATE_STATE_FAILED
        ? "RETRY FROM MAC"
        : "KEEP POWER CONNECTED";
    DrawTextCentered(u8g2, 16, 368, 260, detail);
    u8g2_SendBuffer(u8g2);
    ++g_screen_refreshes;
}

void DrawPage(
    u8g2_t *u8g2,
    Page page,
    const ble_link_snapshot_t &link,
    const ble_link_monitor_data_t &data,
    const battery_monitor::Snapshot &battery)
{
    u8g2_ClearBuffer(u8g2);
    u8g2_SetDrawColor(u8g2, 1);
    DrawHeader(u8g2, page, data, battery);

    switch (page) {
    case Page::kOverview:
        DrawOverviewPage(u8g2, link, data);
        break;
    case Page::kTasks:
        DrawTasksPage(u8g2, data);
        break;
    case Page::kQuota:
        DrawQuotaPage(u8g2, data);
        break;
    case Page::kDevice:
        DrawDevicePage(u8g2, link, data, battery);
        break;
    case Page::kCount:
        return;
    }

    DrawFooter(u8g2, link);
    u8g2_SendBuffer(u8g2);
    ++g_screen_refreshes;
}

void DrawCurrentScreen(
    u8g2_t *u8g2,
    Page page,
    const ble_link_snapshot_t &link,
    const ble_link_monitor_data_t &data,
    const battery_monitor::Snapshot &battery,
    const firmware_update_snapshot_t &update)
{
    if (update.state != FIRMWARE_UPDATE_STATE_IDLE) {
        DrawFirmwareUpdatePage(u8g2, update);
        return;
    }
    DrawPage(u8g2, page, link, data, battery);
}

void IRAM_ATTR WakeInputISR(void *argument)
{
    (void)argument;
    monitor_events_notify_from_isr();
}

void InitWakeInputs()
{
    gpio_config_t key_config = {};
    key_config.pin_bit_mask = 1ULL << board::kKeyPin;
    key_config.mode = GPIO_MODE_INPUT;
    key_config.pull_up_en = GPIO_PULLUP_ENABLE;
    key_config.pull_down_en = GPIO_PULLDOWN_DISABLE;
    key_config.intr_type = GPIO_INTR_ANYEDGE;
    ESP_ERROR_CHECK(gpio_config(&key_config));

    gpio_config_t rtc_config = {};
    rtc_config.pin_bit_mask = 1ULL << board::kRTCInterruptPin;
    rtc_config.mode = GPIO_MODE_INPUT;
    rtc_config.pull_up_en = GPIO_PULLUP_ENABLE;
    rtc_config.pull_down_en = GPIO_PULLDOWN_DISABLE;
    rtc_config.intr_type = GPIO_INTR_NEGEDGE;
    ESP_ERROR_CHECK(gpio_config(&rtc_config));

    const esp_err_t service_result = gpio_install_isr_service(ESP_INTR_FLAG_IRAM);
    if (service_result != ESP_OK && service_result != ESP_ERR_INVALID_STATE) {
        ESP_ERROR_CHECK(service_result);
    }
    ESP_ERROR_CHECK(gpio_isr_handler_add(board::kKeyPin, WakeInputISR, nullptr));
    ESP_ERROR_CHECK(gpio_isr_handler_add(board::kRTCInterruptPin, WakeInputISR, nullptr));

    const uint64_t wakeup_mask = (1ULL << board::kKeyPin)
        | (1ULL << board::kRTCInterruptPin);
    ESP_ERROR_CHECK(esp_sleep_enable_ext1_wakeup_io(
        wakeup_mask,
        ESP_EXT1_WAKEUP_ANY_LOW));
}

uint32_t MainLoopWaitMilliseconds(
    bool raw_released,
    bool stable_released,
    int64_t raw_changed_us,
    int64_t now_us)
{
    uint32_t wait_milliseconds = firmware_update_is_active()
        ? kFirmwareUpdateWaitMilliseconds
        : kIdleWaitMilliseconds;
    if (raw_released == stable_released) {
        return wait_milliseconds;
    }

    const int64_t debounce_remaining_us = kDebounceIntervalUs - (now_us - raw_changed_us);
    if (debounce_remaining_us <= 0) {
        return 1;
    }
    const uint32_t debounce_remaining_ms = static_cast<uint32_t>(
        (debounce_remaining_us + 999) / 1'000);
    return debounce_remaining_ms < wait_milliseconds
        ? debounce_remaining_ms
        : wait_milliseconds;
}

void SampleBatteryAndLog()
{
    const esp_err_t result = battery_monitor::Sample();
    if (result != ESP_OK) {
        ESP_LOGW(kTag, "电池采样不可用：%s", esp_err_to_name(result));
        return;
    }

    const battery_monitor::Snapshot battery = battery_monitor::GetSnapshot();
    if (battery.state == battery_monitor::State::kAvailable) {
        ESP_LOGI(
            kTag,
            "电池=%u%% 电压=%u mV 来源=adc1_gpio4",
            static_cast<unsigned int>(battery.percentage),
            static_cast<unsigned int>(battery.voltage_millivolts));
    } else {
        ESP_LOGI(kTag, "未检测到电池，来源=adc1_gpio4");
    }
}

}  // namespace

extern "C" void app_main(void)
{
    ESP_LOGI(kTag, "TokenRouter Monitor firmware starting");
    ESP_LOGI(kTag,
             "version=%s data_link=ble_protocol_6_secure_pages firmware_update=ble_ota_1",
             kFirmwareVersion);

    monitor_events_initialize();
    ESP_ERROR_CHECK(power_manager::ConfigureAlwaysConnectedMode());
    const esp_err_t board_power_result = board_power::ConfigureUnusedPeripheralsForStandby();
    if (board_power_result != ESP_OK) {
        ESP_LOGW(kTag,
                 "低功耗外设初始化未完全生效：%s",
                 esp_err_to_name(board_power_result));
    }

    u8g2_st7305_config_t display_config = u8g2_st7305_default_config();
    display_config.mosi_io = board::kDisplayMosiPin;
    display_config.sclk_io = board::kDisplayClockPin;
    display_config.dc_io = board::kDisplayDcPin;
    display_config.cs_io = board::kDisplayCsPin;
    display_config.reset_io = board::kDisplayResetPin;
    display_config.rotation = U8G2_R1;
    display_config.tile_buf_height = U8G2_ST7305_TILE_BUF_FULL;

    ESP_ERROR_CHECK(u8g2_st7305_init(&g_display, &display_config));
    ESP_ERROR_CHECK(ble_link_start());
    InitWakeInputs();

    g_psram_bytes = heap_caps_get_total_size(MALLOC_CAP_SPIRAM);
    u8g2_t *u8g2 = u8g2_st7305_get_u8g2(&g_display);
    Page page = Page::kOverview;
    ESP_ERROR_CHECK(ble_link_set_current_page(static_cast<uint8_t>(page)));
    ble_link_snapshot_t link = ble_link_snapshot();
    ble_link_monitor_data_t monitor_data = ble_link_monitor_data();
    battery_monitor::Snapshot battery = battery_monitor::GetSnapshot();
    firmware_update_snapshot_t firmware_update = firmware_update_snapshot();
    DrawCurrentScreen(u8g2, page, link, monitor_data, battery, firmware_update);
    ESP_LOGI(kTag,
             "page=%s rendered: screen=%dx%d psram=%u bytes screen_refreshes=%lu",
             PageName(page),
             board::kDisplayWidth,
             board::kDisplayHeight,
             static_cast<unsigned int>(g_psram_bytes),
             static_cast<unsigned long>(g_screen_refreshes));

    bool raw_released = gpio_get_level(board::kKeyPin) != 0;
    bool stable_released = raw_released;
    int64_t raw_changed_us = esp_timer_get_time();
    int64_t pressed_us = 0;
    const int64_t started_us = raw_changed_us;
    int64_t next_heartbeat_us = started_us + kHeartbeatIntervalUs;
    uint32_t heartbeat = 0;
    bool running_image_confirmation_attempted = false;
    bool running_image_confirmed = false;
    int64_t last_battery_sample_attempt_us = 0;

    while (true) {
        const uint32_t wait_milliseconds = MainLoopWaitMilliseconds(
            raw_released,
            stable_released,
            raw_changed_us,
            esp_timer_get_time());
        monitor_events_wait(wait_milliseconds);
        const int64_t now_us = esp_timer_get_time();
        const bool next_raw_released = gpio_get_level(board::kKeyPin) != 0;

        if (next_raw_released != raw_released) {
            raw_released = next_raw_released;
            raw_changed_us = now_us;
        }

        if (raw_released != stable_released && now_us - raw_changed_us >= kDebounceIntervalUs) {
            stable_released = raw_released;
            if (!stable_released) {
                pressed_us = now_us;
            } else if (pressed_us != 0) {
                const int64_t press_duration_us = now_us - pressed_us;
                pressed_us = 0;
                if (firmware_update_is_active()) {
                    ESP_LOGI(kTag, "key ignored while firmware update is active");
                } else if (press_duration_us < kLongPressIntervalUs) {
                    page = NextPage(page);
                    ESP_ERROR_CHECK_WITHOUT_ABORT(
                        ble_link_set_current_page(static_cast<uint8_t>(page)));
                    link = ble_link_snapshot();
                    monitor_data = ble_link_monitor_data();
                    battery = battery_monitor::GetSnapshot();
                    firmware_update = firmware_update_snapshot();
                    DrawCurrentScreen(
                        u8g2,
                        page,
                        link,
                        monitor_data,
                        battery,
                        firmware_update);
                    ESP_LOGI(kTag,
                             "key=short page=%s screen_refreshes=%lu",
                             PageName(page),
                             static_cast<unsigned long>(g_screen_refreshes));
                } else {
                    const esp_err_t pairing_result = ble_link_open_pairing_window(kPairingWindowSeconds);
                    if (pairing_result == ESP_OK) {
                        ESP_LOGI(kTag,
                                 "key=long action=open_pairing_window duration=%lu s",
                                 static_cast<unsigned long>(kPairingWindowSeconds));
                    } else {
                        ESP_LOGE(kTag,
                                 "key=long action=open_pairing_window failed=%s",
                                 esp_err_to_name(pairing_result));
                    }
                }
            }
        }

        ble_link_tick();
        const int64_t battery_sample_interval_us =
            static_cast<int64_t>(ble_link_battery_sample_interval_seconds()) * 1'000'000LL;
        if (!firmware_update_is_active()
            && (last_battery_sample_attempt_us == 0
                || now_us - last_battery_sample_attempt_us >= battery_sample_interval_us)) {
            last_battery_sample_attempt_us = now_us;
            SampleBatteryAndLog();
        }
        const ble_link_snapshot_t next_link = ble_link_snapshot();
        const ble_link_monitor_data_t next_monitor_data = ble_link_monitor_data();
        const battery_monitor::Snapshot next_battery = battery_monitor::GetSnapshot();
        const firmware_update_snapshot_t next_firmware_update = firmware_update_snapshot();
        if (!running_image_confirmation_attempted
            && next_link.state != BLE_LINK_STATE_STARTING
            && next_link.state != BLE_LINK_STATE_ERROR) {
            running_image_confirmation_attempted = true;
            const esp_err_t confirmation_result = firmware_update_confirm_running_image();
            if (confirmation_result != ESP_OK) {
                ESP_LOGE(kTag,
                         "running image confirmation failed: %s",
                         esp_err_to_name(confirmation_result));
            } else {
                running_image_confirmed = true;
            }
        }
        if (running_image_confirmed
            && !firmware_update_is_active()
            && !next_link.pairing_window_open
            && night_sleep_should_enter()) {
            const esp_err_t prepare_result = night_sleep_prepare_deep_sleep();
            if (prepare_result != ESP_OK) {
                ESP_LOGW(kTag, "夜间Deep-sleep准备失败：%s", esp_err_to_name(prepare_result));
            } else {
                const esp_err_t display_sleep_result = u8g2_st7305_enter_sleep(&g_display);
                if (display_sleep_result != ESP_OK) {
                    ESP_LOGW(kTag,
                             "显示屏进入SLPIN失败，仍继续Deep-sleep：%s",
                             esp_err_to_name(display_sleep_result));
                }
                night_sleep_start_deep_sleep();
            }
        }
        if (next_link.state != link.state
            || next_link.connected != link.connected
            || next_link.handshake_ready != link.handshake_ready
            || next_link.encrypted != link.encrypted
            || next_link.bonded != link.bonded
            || next_link.pairing_window_open != link.pairing_window_open
            || next_link.current_page != link.current_page
            || next_link.last_error != link.last_error
            || next_monitor_data.revision != monitor_data.revision
            || next_battery.revision != battery.revision
            || next_firmware_update.revision != firmware_update.revision) {
            link = next_link;
            monitor_data = next_monitor_data;
            battery = next_battery;
            firmware_update = next_firmware_update;
            DrawCurrentScreen(
                u8g2,
                page,
                link,
                monitor_data,
                battery,
                firmware_update);
            ESP_LOGI(kTag,
                     "ble_state=%s connected=%u encrypted=%u bonded=%u handshake_ready=%u pairing_window=%u mac_online=%u network=%u tokenrouter=%u data_revision=%lu update_state=%s update_progress=%u update_error=%u error=%d page=%s screen_refreshes=%lu",
                     ble_link_state_name(link.state),
                     link.connected ? 1U : 0U,
                     link.encrypted ? 1U : 0U,
                     link.bonded ? 1U : 0U,
                     link.handshake_ready ? 1U : 0U,
                     link.pairing_window_open ? 1U : 0U,
                     monitor_data.mac_online ? 1U : 0U,
                     monitor_data.network_online ? 1U : 0U,
                     monitor_data.tokenrouter_online ? 1U : 0U,
                     static_cast<unsigned long>(monitor_data.revision),
                     firmware_update_state_name(firmware_update.state),
                     static_cast<unsigned int>(firmware_update.progress_percent),
                     static_cast<unsigned int>(firmware_update.error),
                     link.last_error,
                     PageName(page),
                     static_cast<unsigned long>(g_screen_refreshes));
        }

        if (now_us >= next_heartbeat_us) {
            ++heartbeat;
            const uint64_t uptime_seconds = static_cast<uint64_t>((now_us - started_us) / 1'000'000);
            ESP_LOGI(kTag,
                     "heartbeat=%lu uptime=%llu s page=%s ble_state=%s screen_refreshes=%lu",
                     static_cast<unsigned long>(heartbeat),
                     static_cast<unsigned long long>(uptime_seconds),
                     PageName(page),
                     ble_link_state_name(link.state),
                     static_cast<unsigned long>(g_screen_refreshes));
            next_heartbeat_us += kHeartbeatIntervalUs;
        }
    }
}
