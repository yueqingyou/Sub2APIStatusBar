#include "night_sleep.h"

#include <cstdint>

#include "driver/gpio.h"
#include "driver/rtc_io.h"
#include "esp_attr.h"
#include "esp_log.h"
#include "esp_rom_sys.h"
#include "esp_sleep.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "nvs.h"

#include "board_config.h"
#include "monitor_events.h"
#include "pcf85063.h"
#include "power_manager.h"

namespace {

constexpr char kTag[] = "night_sleep";
constexpr char kNVSNamespace[] = "night_sleep";
constexpr char kNVSEnabledKey[] = "enabled";
constexpr char kNVSStartMinuteKey[] = "start_min";
constexpr char kNVSEndMinuteKey[] = "end_min";
constexpr char kNVSClockSynchronizedKey[] = "rtc_synced";
constexpr uint32_t kManualOverrideMagic = 0x4E534C50U;
constexpr uint32_t kSleepSessionMagic = 0x534C4550U;
constexpr int64_t kClockCheckIntervalMicroseconds = 60'000'000;
constexpr int64_t kApplyGracePeriodMicroseconds = 2'000'000;
constexpr int64_t kBootGracePeriodMicroseconds = 30'000'000;
constexpr uint64_t kTimerWakeupMarginSeconds = 5;
constexpr unsigned int kWakePinStableSampleCount = 5;
constexpr uint32_t kWakePinStableSampleDelayMicroseconds = 200;

RTC_DATA_ATTR uint32_t g_manual_override_marker;
RTC_DATA_ATTR uint32_t g_sleep_session_marker;
RTC_DATA_ATTR uint8_t g_sleep_session_rtc_armed;
RTC_DATA_ATTR uint8_t g_boot_sequence;

SemaphoreHandle_t g_mutex;
night_sleep_snapshot_t g_snapshot = {
    .enabled = true,
    .clock_synchronized = false,
    .manual_override = false,
    .rtc_wake_fallback = false,
    .boot_sequence_parity = false,
    .last_wakeup_reason = NIGHT_SLEEP_WAKEUP_UNKNOWN,
    .start_minute = NIGHT_SLEEP_DEFAULT_START_MINUTE,
    .end_minute = NIGHT_SLEEP_DEFAULT_END_MINUTE,
};
pcf85063::DateTime g_current_time = {};
bool g_sleep_due;
bool g_clock_was_synchronized;
int64_t g_next_clock_check_us;
int64_t g_sleep_not_before_us;
bool g_previous_rtc_wake;
bool g_force_timer_only;
bool g_rtc_wake_armed;
bool g_automatic_light_sleep_disabled;

class ScopedLock {
public:
    ScopedLock()
        : locked_(g_mutex != nullptr && xSemaphoreTake(g_mutex, portMAX_DELAY) == pdTRUE)
    {
    }

    ~ScopedLock()
    {
        if (locked_) {
            xSemaphoreGive(g_mutex);
        }
    }

    bool locked() const { return locked_; }

private:
    bool locked_;
};

bool IsScheduleValid(uint16_t start_minute, uint16_t end_minute)
{
    return start_minute < 1'440U && end_minute < 1'440U && start_minute != end_minute;
}

bool IsInsideWindow(uint16_t minute_of_day, uint16_t start_minute, uint16_t end_minute)
{
    if (start_minute < end_minute) {
        return minute_of_day >= start_minute && minute_of_day < end_minute;
    }
    return minute_of_day >= start_minute || minute_of_day < end_minute;
}

uint16_t MinuteOfDay(const pcf85063::DateTime &date_time)
{
    return static_cast<uint16_t>(date_time.hour * 60U + date_time.minute);
}

uint32_t SecondsUntilEnd(const pcf85063::DateTime &date_time, uint16_t end_minute)
{
    const uint32_t now_seconds = static_cast<uint32_t>(date_time.hour) * 3'600U
        + static_cast<uint32_t>(date_time.minute) * 60U
        + date_time.second;
    const uint32_t end_seconds = static_cast<uint32_t>(end_minute) * 60U;
    return (end_seconds + 86'400U - now_seconds) % 86'400U;
}

esp_err_t SaveScheduleLocked()
{
    nvs_handle_t handle = 0;
    esp_err_t result = nvs_open(kNVSNamespace, NVS_READWRITE, &handle);
    if (result == ESP_OK) {
        result = nvs_set_u8(handle, kNVSEnabledKey, g_snapshot.enabled ? 1U : 0U);
    }
    if (result == ESP_OK) {
        result = nvs_set_u16(handle, kNVSStartMinuteKey, g_snapshot.start_minute);
    }
    if (result == ESP_OK) {
        result = nvs_set_u16(handle, kNVSEndMinuteKey, g_snapshot.end_minute);
    }
    if (result == ESP_OK) {
        result = nvs_commit(handle);
    }
    if (handle != 0) {
        nvs_close(handle);
    }
    return result;
}

esp_err_t SaveClockSynchronizedLocked()
{
    nvs_handle_t handle = 0;
    esp_err_t result = nvs_open(kNVSNamespace, NVS_READWRITE, &handle);
    if (result == ESP_OK) {
        result = nvs_set_u8(
            handle,
            kNVSClockSynchronizedKey,
            g_clock_was_synchronized ? 1U : 0U);
    }
    if (result == ESP_OK) {
        result = nvs_commit(handle);
    }
    if (handle != 0) {
        nvs_close(handle);
    }
    return result;
}

void LoadScheduleLocked()
{
    nvs_handle_t handle = 0;
    if (nvs_open(kNVSNamespace, NVS_READONLY, &handle) != ESP_OK) {
        return;
    }

    uint8_t enabled = 1;
    uint8_t clock_synchronized = 0;
    uint16_t start_minute = NIGHT_SLEEP_DEFAULT_START_MINUTE;
    uint16_t end_minute = NIGHT_SLEEP_DEFAULT_END_MINUTE;
    nvs_get_u8(handle, kNVSEnabledKey, &enabled);
    nvs_get_u16(handle, kNVSStartMinuteKey, &start_minute);
    nvs_get_u16(handle, kNVSEndMinuteKey, &end_minute);
    nvs_get_u8(handle, kNVSClockSynchronizedKey, &clock_synchronized);
    nvs_close(handle);

    if (!IsScheduleValid(start_minute, end_minute)) {
        start_minute = NIGHT_SLEEP_DEFAULT_START_MINUTE;
        end_minute = NIGHT_SLEEP_DEFAULT_END_MINUTE;
    }
    g_snapshot.enabled = enabled != 0;
    g_snapshot.start_minute = start_minute;
    g_snapshot.end_minute = end_minute;
    g_clock_was_synchronized = clock_synchronized == 1U;
}

esp_err_t ConfigureAlarmLocked(bool inside_window)
{
    if (!g_snapshot.enabled || !g_snapshot.clock_synchronized) {
        return pcf85063::DisableAlarm();
    }
    const uint16_t alarm_minute = inside_window
        ? g_snapshot.end_minute
        : g_snapshot.start_minute;
    return pcf85063::ConfigureDailyAlarm(
        static_cast<uint8_t>(alarm_minute / 60U),
        static_cast<uint8_t>(alarm_minute % 60U),
        0);
}

esp_err_t RefreshClockLocked(bool clear_alarm)
{
    if (!g_clock_was_synchronized) {
        g_snapshot.clock_synchronized = false;
        g_sleep_due = false;
        g_next_clock_check_us = INT64_MAX;
        return ESP_ERR_INVALID_STATE;
    }
    if (clear_alarm) {
        const esp_err_t clear_result = pcf85063::ClearAlarmFlag();
        if (clear_result != ESP_OK) {
            return clear_result;
        }
    }

    pcf85063::DateTime date_time = {};
    const esp_err_t result = pcf85063::ReadDateTime(&date_time);
    if (result != ESP_OK) {
        const esp_err_t disable_result = pcf85063::DisableAlarm();
        if (disable_result != ESP_OK) {
            ESP_LOGW(kTag, "RTC告警关闭失败：%s", esp_err_to_name(disable_result));
        }
        g_snapshot.clock_synchronized = false;
        g_sleep_due = false;
        g_next_clock_check_us = esp_timer_get_time() + kClockCheckIntervalMicroseconds;
        return result;
    }

    g_current_time = date_time;
    g_snapshot.clock_synchronized = true;
    const bool inside_window = IsInsideWindow(
        MinuteOfDay(date_time),
        g_snapshot.start_minute,
        g_snapshot.end_minute);
    if (!inside_window) {
        g_manual_override_marker = 0;
    }
    if (!g_snapshot.enabled || !inside_window) {
        g_force_timer_only = false;
    }
    g_snapshot.manual_override = g_manual_override_marker == kManualOverrideMagic;
    g_sleep_due = g_snapshot.enabled && inside_window && !g_snapshot.manual_override;
    g_next_clock_check_us = esp_timer_get_time() + kClockCheckIntervalMicroseconds;
    return ConfigureAlarmLocked(inside_window);
}

void ReleaseWakePinHolds()
{
    rtc_gpio_hold_dis(board::kRTCInterruptPin);
    rtc_gpio_hold_dis(board::kKeyPin);
    rtc_gpio_deinit(board::kRTCInterruptPin);
    rtc_gpio_deinit(board::kKeyPin);
}

void CaptureWakeReason()
{
    const bool expected_sleep_session = g_sleep_session_marker == kSleepSessionMagic;
    const bool rtc_was_armed = g_sleep_session_rtc_armed != 0;
    g_sleep_session_marker = 0;
    g_sleep_session_rtc_armed = 0;
    g_previous_rtc_wake = false;

    const esp_sleep_wakeup_cause_t wakeup_cause = esp_sleep_get_wakeup_cause();
    if (wakeup_cause == ESP_SLEEP_WAKEUP_UNDEFINED) {
        g_boot_sequence = 0;
    } else {
        ++g_boot_sequence;
    }
    g_snapshot.boot_sequence_parity = (g_boot_sequence & 0x01U) != 0;
    if (wakeup_cause == ESP_SLEEP_WAKEUP_TIMER) {
        g_snapshot.last_wakeup_reason = NIGHT_SLEEP_WAKEUP_TIMER;
        return;
    }
    if (wakeup_cause != ESP_SLEEP_WAKEUP_EXT1) {
        g_snapshot.last_wakeup_reason = wakeup_cause == ESP_SLEEP_WAKEUP_UNDEFINED
            ? NIGHT_SLEEP_WAKEUP_UNKNOWN
            : NIGHT_SLEEP_WAKEUP_OTHER;
        return;
    }
    const uint64_t wakeup_pins = esp_sleep_get_ext1_wakeup_status();
    if ((wakeup_pins & (1ULL << board::kKeyPin)) != 0) {
        g_snapshot.last_wakeup_reason = NIGHT_SLEEP_WAKEUP_KEY;
        g_manual_override_marker = kManualOverrideMagic;
        ESP_LOGI(kTag, "实体KEY提前唤醒：跳过当前北京时间休眠窗口");
    } else if (expected_sleep_session
               && rtc_was_armed
               && (wakeup_pins & (1ULL << board::kRTCInterruptPin)) != 0) {
        g_snapshot.last_wakeup_reason = NIGHT_SLEEP_WAKEUP_RTC_INTERRUPT;
        g_previous_rtc_wake = true;
    } else {
        g_snapshot.last_wakeup_reason = NIGHT_SLEEP_WAKEUP_OTHER;
    }
}

esp_err_t ConfigureDeepSleepPin(gpio_num_t pin)
{
    esp_err_t result = rtc_gpio_init(pin);
    if (result == ESP_OK) {
        result = rtc_gpio_set_direction(pin, RTC_GPIO_MODE_INPUT_ONLY);
    }
    if (result == ESP_OK) {
        result = rtc_gpio_pullup_en(pin);
    }
    if (result == ESP_OK) {
        result = rtc_gpio_pulldown_dis(pin);
    }
    return result;
}

bool IsWakePinStableHigh(gpio_num_t pin)
{
    for (unsigned int sample = 0; sample < kWakePinStableSampleCount; ++sample) {
        if (rtc_gpio_get_level(pin) == 0) {
            return false;
        }
        esp_rom_delay_us(kWakePinStableSampleDelayMicroseconds);
    }
    return true;
}

void ResetPreparedSleepState()
{
    g_sleep_session_marker = 0;
    g_sleep_session_rtc_armed = 0;
    g_rtc_wake_armed = false;
    esp_sleep_disable_wakeup_source(ESP_SLEEP_WAKEUP_ALL);
    esp_sleep_pd_config(ESP_PD_DOMAIN_RTC_PERIPH, ESP_PD_OPTION_AUTO);
    ReleaseWakePinHolds();
    if (g_automatic_light_sleep_disabled) {
        const esp_err_t restore_result = power_manager::ConfigureAlwaysConnectedMode();
        if (restore_result != ESP_OK) {
            ESP_LOGE(kTag, "自动Light-sleep恢复失败：%s", esp_err_to_name(restore_result));
        }
        g_automatic_light_sleep_disabled = false;
    }
}

}  // namespace

extern "C" esp_err_t night_sleep_initialize(void)
{
    if (g_mutex == nullptr) {
        g_mutex = xSemaphoreCreateMutex();
    }
    if (g_mutex == nullptr) {
        return ESP_ERR_NO_MEM;
    }
    ReleaseWakePinHolds();
    CaptureWakeReason();

    ScopedLock lock;
    if (!lock.locked()) {
        return ESP_ERR_INVALID_STATE;
    }
    LoadScheduleLocked();
    g_sleep_not_before_us = esp_timer_get_time() + kBootGracePeriodMicroseconds;
    esp_err_t result;
    if (g_clock_was_synchronized) {
        result = RefreshClockLocked(true);
    } else {
        g_snapshot.clock_synchronized = false;
        g_sleep_due = false;
        g_next_clock_check_us = INT64_MAX;
        result = pcf85063::DisableAlarm();
        if (result == ESP_OK) {
            ESP_LOGI(kTag, "RTC等待Mac下发北京时间，夜间休眠暂不执行");
        }
    }
    if (result == ESP_OK && g_previous_rtc_wake && g_sleep_due) {
        g_force_timer_only = true;
        ESP_LOGW(kTag, "RTC在休眠结束前唤醒，当前窗口改用定时器+KEY，防止重启循环");
    }
    if (result == ESP_OK && g_snapshot.clock_synchronized) {
        ESP_LOGI(kTag,
                 "北京时间计划=%s %02u:%02u-%02u:%02u RTC=已同步 人工覆盖=%u",
                 g_snapshot.enabled ? "启用" : "关闭",
                 static_cast<unsigned int>(g_snapshot.start_minute / 60U),
                 static_cast<unsigned int>(g_snapshot.start_minute % 60U),
                 static_cast<unsigned int>(g_snapshot.end_minute / 60U),
                 static_cast<unsigned int>(g_snapshot.end_minute % 60U),
                 g_snapshot.manual_override ? 1U : 0U);
    } else if (result != ESP_OK) {
        ESP_LOGW(kTag, "RTC时间尚未同步：%s", esp_err_to_name(result));
    }
    return result == ESP_ERR_INVALID_STATE ? ESP_OK : result;
}

extern "C" esp_err_t night_sleep_apply_schedule(
    bool enabled,
    uint16_t start_minute,
    uint16_t end_minute,
    uint16_t year,
    uint8_t month,
    uint8_t day,
    uint8_t weekday,
    uint8_t hour,
    uint8_t minute,
    uint8_t second)
{
    if (!IsScheduleValid(start_minute, end_minute)) {
        return ESP_ERR_INVALID_ARG;
    }
    const pcf85063::DateTime date_time = {
        .year = year,
        .month = month,
        .day = day,
        .weekday = weekday,
        .hour = hour,
        .minute = minute,
        .second = second,
    };

    ScopedLock lock;
    if (!lock.locked()) {
        return ESP_ERR_INVALID_STATE;
    }
    const bool schedule_changed = g_snapshot.enabled != enabled
        || g_snapshot.start_minute != start_minute
        || g_snapshot.end_minute != end_minute;
    g_snapshot.enabled = enabled;
    g_snapshot.start_minute = start_minute;
    g_snapshot.end_minute = end_minute;
    esp_err_t result = schedule_changed ? SaveScheduleLocked() : ESP_OK;
    if (result == ESP_OK) {
        result = pcf85063::SetDateTime(date_time);
    }
    if (result == ESP_OK && !g_clock_was_synchronized) {
        g_clock_was_synchronized = true;
        result = SaveClockSynchronizedLocked();
        if (result != ESP_OK) {
            g_clock_was_synchronized = false;
        }
    }
    if (result == ESP_OK) {
        result = RefreshClockLocked(true);
    }
    if (result != ESP_OK) {
        ESP_LOGE(kTag, "北京时间计划同步失败：%s", esp_err_to_name(result));
        return result;
    }

    g_sleep_not_before_us = esp_timer_get_time() + kApplyGracePeriodMicroseconds;
    ESP_LOGI(kTag,
             "北京时间计划已同步：%s %02u:%02u-%02u:%02u 当前=%04u-%02u-%02u %02u:%02u:%02u",
             enabled ? "启用" : "关闭",
             static_cast<unsigned int>(start_minute / 60U),
             static_cast<unsigned int>(start_minute % 60U),
             static_cast<unsigned int>(end_minute / 60U),
             static_cast<unsigned int>(end_minute % 60U),
             static_cast<unsigned int>(year),
             static_cast<unsigned int>(month),
             static_cast<unsigned int>(day),
             static_cast<unsigned int>(hour),
             static_cast<unsigned int>(minute),
             static_cast<unsigned int>(second));
    monitor_events_notify();
    return ESP_OK;
}

extern "C" night_sleep_snapshot_t night_sleep_snapshot(void)
{
    ScopedLock lock;
    if (!lock.locked()) {
        return night_sleep_snapshot_t{};
    }
    night_sleep_snapshot_t snapshot = g_snapshot;
    snapshot.rtc_wake_fallback = g_force_timer_only;
    return snapshot;
}

extern "C" bool night_sleep_should_enter(void)
{
    ScopedLock lock;
    if (!lock.locked()) {
        return false;
    }
    const int64_t now_us = esp_timer_get_time();
    const bool alarm_asserted = gpio_get_level(board::kRTCInterruptPin) == 0;
    if (alarm_asserted || now_us >= g_next_clock_check_us) {
        const esp_err_t result = RefreshClockLocked(alarm_asserted);
        if (result != ESP_OK) {
            ESP_LOGW(kTag, "RTC计划检查失败：%s", esp_err_to_name(result));
            return false;
        }
    }
    return g_sleep_due && now_us >= g_sleep_not_before_us;
}

extern "C" esp_err_t night_sleep_prepare_deep_sleep(void)
{
    uint32_t sleep_seconds = 0;
    {
        ScopedLock lock;
        if (!lock.locked()) {
            return ESP_ERR_INVALID_STATE;
        }
        esp_err_t result = RefreshClockLocked(gpio_get_level(board::kRTCInterruptPin) == 0);
        if (result != ESP_OK || !g_sleep_due) {
            return result == ESP_OK ? ESP_ERR_INVALID_STATE : result;
        }
        sleep_seconds = SecondsUntilEnd(g_current_time, g_snapshot.end_minute);
        if (sleep_seconds == 0 || sleep_seconds >= 86'400U) {
            return ESP_ERR_INVALID_STATE;
        }
    }

    if (gpio_get_level(board::kKeyPin) == 0) {
        return ESP_ERR_INVALID_STATE;
    }

    esp_err_t result = power_manager::DisableAutomaticLightSleepForDeepSleep();
    if (result != ESP_OK) {
        return result;
    }
    g_automatic_light_sleep_disabled = true;

    result = esp_sleep_disable_wakeup_source(ESP_SLEEP_WAKEUP_ALL);
    if (result != ESP_OK) {
        ResetPreparedSleepState();
        return result;
    }
    result = ConfigureDeepSleepPin(board::kKeyPin);
    bool use_rtc_wake = !g_force_timer_only;
    if (result == ESP_OK && use_rtc_wake) {
        result = ConfigureDeepSleepPin(board::kRTCInterruptPin);
    }
    if (result == ESP_OK && !IsWakePinStableHigh(board::kKeyPin)) {
        result = ESP_ERR_INVALID_STATE;
    }
    if (result == ESP_OK && use_rtc_wake
        && !IsWakePinStableHigh(board::kRTCInterruptPin)) {
        use_rtc_wake = false;
        rtc_gpio_deinit(board::kRTCInterruptPin);
        ESP_LOGW(kTag, "RTC_INT入睡前不是稳定高电平，当前窗口改用定时器+KEY");
    }
    if (result == ESP_OK) {
        const uint64_t wakeup_mask = (1ULL << board::kKeyPin)
            | (use_rtc_wake ? (1ULL << board::kRTCInterruptPin) : 0ULL);
        result = esp_sleep_enable_ext1_wakeup_io(wakeup_mask, ESP_EXT1_WAKEUP_ANY_LOW);
    }
    if (result == ESP_OK) {
        result = esp_sleep_pd_config(
            ESP_PD_DOMAIN_RTC_PERIPH,
            use_rtc_wake ? ESP_PD_OPTION_ON : ESP_PD_OPTION_AUTO);
    }
    if (result == ESP_OK) {
        result = esp_sleep_enable_timer_wakeup(
            (static_cast<uint64_t>(sleep_seconds) + kTimerWakeupMarginSeconds) * 1'000'000ULL);
    }
    if (result != ESP_OK) {
        ResetPreparedSleepState();
        return result;
    }

    g_rtc_wake_armed = use_rtc_wake;
    g_sleep_session_marker = kSleepSessionMagic;
    g_sleep_session_rtc_armed = use_rtc_wake ? 1U : 0U;
    ESP_LOGI(kTag,
             "夜间Deep-sleep已准备：%lu 秒 %s+定时器+KEY唤醒",
             static_cast<unsigned long>(sleep_seconds),
             use_rtc_wake ? "RTC告警" : "RTC异常降级");
    return ESP_OK;
}

extern "C" void night_sleep_start_deep_sleep(void)
{
    if (g_rtc_wake_armed && rtc_gpio_get_level(board::kRTCInterruptPin) == 0) {
        const uint64_t rtc_mask = 1ULL << board::kRTCInterruptPin;
        const esp_err_t disable_result = esp_sleep_disable_ext1_wakeup_io(rtc_mask);
        if (disable_result == ESP_OK) {
            g_rtc_wake_armed = false;
            g_sleep_session_rtc_armed = 0;
            esp_sleep_pd_config(ESP_PD_DOMAIN_RTC_PERIPH, ESP_PD_OPTION_AUTO);
            ESP_LOGW(kTag, "RTC_INT在入睡瞬间拉低，已改用定时器+KEY避免立即唤醒");
        } else {
            ESP_LOGE(kTag, "RTC_INT唤醒源移除失败：%s", esp_err_to_name(disable_result));
        }
    }
    ESP_LOGI(kTag, "进入夜间Deep-sleep");
    esp_deep_sleep_start();
}
