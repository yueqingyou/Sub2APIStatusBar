#include <cstdint>
#include <cstdio>

#include "driver/gpio.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "board_config.h"
#include "ble_link.h"
#include "u8g2_st7305.h"

namespace {

constexpr char kTag[] = "monitor";
constexpr char kFirmwareVersion[] = MONITOR_FIRMWARE_VERSION_STRING;
constexpr int64_t kHeartbeatIntervalUs = 10'000'000;
constexpr int64_t kDebounceIntervalUs = 50'000;
constexpr int64_t kLongPressIntervalUs = 1'500'000;
constexpr uint32_t kPairingWindowSeconds = 60;
constexpr TickType_t kKeyPollInterval = pdMS_TO_TICKS(20);

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
    const ble_link_monitor_data_t &data)
{
    u8g2_SetFont(u8g2, u8g2_font_helvB14_tf);
    u8g2_DrawStr(u8g2, 16, 25, PageDisplayName(page));

    char page_text[32];
    if (page != Page::kDevice) {
        std::snprintf(page_text,
                      sizeof(page_text),
                      "%s  %u / %u",
                      PageDataStatus(page, data),
                      static_cast<unsigned int>(page) + 1U,
                      static_cast<unsigned int>(Page::kCount));
    } else {
        std::snprintf(page_text,
                      sizeof(page_text),
                      "%u / %u",
                      static_cast<unsigned int>(page) + 1U,
                      static_cast<unsigned int>(Page::kCount));
    }
    u8g2_SetFont(u8g2, u8g2_font_5x8_tf);
    const int page_width = static_cast<int>(u8g2_GetStrWidth(u8g2, page_text));
    u8g2_DrawStr(u8g2, board::kDisplayWidth - 16 - page_width, 22, page_text);
}

const char *BleFooterStatus(const ble_link_snapshot_t &link)
{
    switch (link.state) {
    case BLE_LINK_STATE_STARTING:
        return "BLE STARTING";
    case BLE_LINK_STATE_UNPAIRED:
        return "HOLD KEY TO PAIR";
    case BLE_LINK_STATE_ADVERTISING:
        return "BLE ADVERTISING";
    case BLE_LINK_STATE_PAIRING:
        return "PAIRING OPEN";
    case BLE_LINK_STATE_SECURING:
        return "SECURING LINK";
    case BLE_LINK_STATE_CONNECTED:
        return "MAC CONNECTED";
    case BLE_LINK_STATE_READY:
        return "MAC LINK READY";
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
    u8g2_SetFont(u8g2, u8g2_font_6x12_tf);
    u8g2_DrawStr(u8g2, 16, 284, "KEY NEXT  HOLD PAIR");

    if (link.state == BLE_LINK_STATE_READY) {
        return;
    }
    const char *status = BleFooterStatus(link);
    const int status_width = static_cast<int>(u8g2_GetStrWidth(u8g2, status));
    u8g2_DrawStr(u8g2, board::kDisplayWidth - 16 - status_width, 284, status);
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
        52,
        96,
        "TODAY COST",
        cost_text,
        data.overview_valid ? u8g2_font_inb30_mf : u8g2_font_helvB24_tf,
        u8g2_font_helvB24_tf);

    DrawLabeledValue(
        u8g2, 16, 178, 132, 169, "REQUESTS", request_text, u8g2_font_helvB24_tf);
    DrawLabeledValue(
        u8g2, 206, 178, 132, 169, "TOKENS", token_text, u8g2_font_helvB24_tf);

    DrawLabeledValue(
        u8g2,
        16,
        116,
        210,
        238,
        "MAC",
        MacConnectionStatus(link, data),
        u8g2_font_helvB10_tf,
        u8g2_font_6x12_tf);
    DrawLabeledValue(
        u8g2,
        142,
        116,
        210,
        238,
        "NETWORK",
        NetworkStatus(data),
        u8g2_font_helvB10_tf,
        u8g2_font_6x12_tf);
    DrawLabeledValue(
        u8g2,
        268,
        116,
        210,
        238,
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
        55,
        112,
        "RECENT RESULTS",
        total_text,
        has_data ? u8g2_font_logisoso42_tn : u8g2_font_helvB24_tf,
        u8g2_font_helvB24_tf);

    if (!has_data) {
        u8g2_SetFont(u8g2, u8g2_font_5x8_tf);
        DrawTextCentered(u8g2, 16, 368, 137, "WAITING FOR TASK DATA");
    }

    DrawLabeledValue(
        u8g2, 16, 116, 181, 223, "DONE", done_text, u8g2_font_helvB24_tf);
    DrawLabeledValue(
        u8g2, 142, 116, 181, 223, "ERROR", error_text, u8g2_font_helvB24_tf);
    DrawLabeledValue(
        u8g2, 268, 116, 181, 223, "STALE", stale_text, u8g2_font_helvB24_tf);
}

void DrawQuotaPage(u8g2_t *u8g2, const ble_link_monitor_data_t &data)
{
    char five_hour[20];
    char seven_day[20];
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

    char normal_accounts[20];
    if (data.quota_normal_accounts_valid) {
        std::snprintf(
            normal_accounts,
            sizeof(normal_accounts),
            "%lu",
            static_cast<unsigned long>(data.quota_normal_accounts));
    } else {
        std::snprintf(normal_accounts, sizeof(normal_accounts), "--");
    }

    DrawLabeledValue(
        u8g2,
        16,
        178,
        53,
        104,
        "5 HOUR REMAINING",
        five_hour,
        data.quota_five_hour_valid ? u8g2_font_inb30_mf : u8g2_font_helvB24_tf,
        u8g2_font_helvB24_tf);
    DrawLabeledValue(
        u8g2,
        206,
        178,
        53,
        104,
        "7 DAY REMAINING",
        seven_day,
        data.quota_seven_day_valid ? u8g2_font_inb30_mf : u8g2_font_helvB24_tf,
        u8g2_font_helvB24_tf);

    DrawLabeledValue(
        u8g2, 111, 178, 160, 202, "NORMAL ACCOUNTS", normal_accounts, u8g2_font_helvB24_tf);
}

void DrawDevicePage(
    u8g2_t *u8g2,
    const ble_link_snapshot_t &link,
    const ble_link_monitor_data_t &data)
{
    const char *mac_status = MacConnectionStatus(link, data);

    u8g2_SetFont(u8g2, u8g2_font_6x12_tf);
    DrawTextCentered(u8g2, 16, 368, 54, "MAC STATUS");
    DrawTextCenteredWithFallback(
        u8g2,
        16,
        368,
        99,
        mac_status,
        u8g2_font_helvB24_tf,
        u8g2_font_helvB18_tf);

    u8g2_SetFont(u8g2, u8g2_font_helvR12_tf);
    u8g2_DrawStr(u8g2, 24, 151, "BLE LINK");
    u8g2_SetFont(u8g2, u8g2_font_helvB14_tf);
    DrawTextRightAligned(u8g2, 376, 151, BleSecurityStatus(link));

    u8g2_SetFont(u8g2, u8g2_font_helvR12_tf);
    u8g2_DrawStr(u8g2, 24, 199, "DATA STATE");
    u8g2_SetFont(u8g2, u8g2_font_helvB14_tf);
    DrawTextRightAligned(u8g2, 376, 199, PageDataStatus(Page::kDevice, data));

    u8g2_SetFont(u8g2, u8g2_font_helvR12_tf);
    u8g2_DrawStr(u8g2, 24, 247, "FIRMWARE");
    u8g2_SetFont(u8g2, u8g2_font_helvB14_tf);
    DrawTextRightAligned(u8g2, 376, 247, kFirmwareVersion);
}

void DrawPage(
    u8g2_t *u8g2,
    Page page,
    const ble_link_snapshot_t &link,
    const ble_link_monitor_data_t &data)
{
    u8g2_ClearBuffer(u8g2);
    u8g2_SetDrawColor(u8g2, 1);
    DrawHeader(u8g2, page, data);

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
        DrawDevicePage(u8g2, link, data);
        break;
    case Page::kCount:
        return;
    }

    DrawFooter(u8g2, link);
    u8g2_SendBuffer(u8g2);
    ++g_screen_refreshes;
}

void InitKey()
{
    gpio_config_t config = {};
    config.pin_bit_mask = 1ULL << board::kKeyPin;
    config.mode = GPIO_MODE_INPUT;
    config.pull_up_en = GPIO_PULLUP_ENABLE;
    config.pull_down_en = GPIO_PULLDOWN_DISABLE;
    config.intr_type = GPIO_INTR_DISABLE;
    ESP_ERROR_CHECK(gpio_config(&config));
}

}  // namespace

extern "C" void app_main(void)
{
    ESP_LOGI(kTag, "TokenRouter Monitor firmware starting");
    ESP_LOGI(kTag,
             "version=%s-data-sync data_link=ble_protocol_2_secure_pages",
             kFirmwareVersion);

    u8g2_st7305_config_t display_config = u8g2_st7305_default_config();
    display_config.mosi_io = board::kDisplayMosiPin;
    display_config.sclk_io = board::kDisplayClockPin;
    display_config.dc_io = board::kDisplayDcPin;
    display_config.cs_io = board::kDisplayCsPin;
    display_config.reset_io = board::kDisplayResetPin;
    display_config.rotation = U8G2_R1;
    display_config.tile_buf_height = U8G2_ST7305_TILE_BUF_FULL;

    ESP_ERROR_CHECK(u8g2_st7305_init(&g_display, &display_config));
    InitKey();
    ESP_ERROR_CHECK(ble_link_start());

    g_psram_bytes = heap_caps_get_total_size(MALLOC_CAP_SPIRAM);
    u8g2_t *u8g2 = u8g2_st7305_get_u8g2(&g_display);
    Page page = Page::kOverview;
    ESP_ERROR_CHECK(ble_link_set_current_page(static_cast<uint8_t>(page)));
    ble_link_snapshot_t link = ble_link_snapshot();
    ble_link_monitor_data_t monitor_data = ble_link_monitor_data();
    DrawPage(u8g2, page, link, monitor_data);
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

    while (true) {
        vTaskDelay(kKeyPollInterval);
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
                if (press_duration_us < kLongPressIntervalUs) {
                    page = NextPage(page);
                    ESP_ERROR_CHECK_WITHOUT_ABORT(
                        ble_link_set_current_page(static_cast<uint8_t>(page)));
                    link = ble_link_snapshot();
                    monitor_data = ble_link_monitor_data();
                    DrawPage(u8g2, page, link, monitor_data);
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
        const ble_link_snapshot_t next_link = ble_link_snapshot();
        const ble_link_monitor_data_t next_monitor_data = ble_link_monitor_data();
        if (next_link.state != link.state
            || next_link.connected != link.connected
            || next_link.handshake_ready != link.handshake_ready
            || next_link.encrypted != link.encrypted
            || next_link.bonded != link.bonded
            || next_link.pairing_window_open != link.pairing_window_open
            || next_link.current_page != link.current_page
            || next_link.last_error != link.last_error
            || next_monitor_data.revision != monitor_data.revision) {
            link = next_link;
            monitor_data = next_monitor_data;
            DrawPage(u8g2, page, link, monitor_data);
            ESP_LOGI(kTag,
                     "ble_state=%s connected=%u encrypted=%u bonded=%u handshake_ready=%u pairing_window=%u mac_online=%u network=%u tokenrouter=%u data_revision=%lu error=%d page=%s screen_refreshes=%lu",
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
