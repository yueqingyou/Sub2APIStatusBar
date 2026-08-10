#include "power_manager.h"

#include "esp_log.h"
#include "esp_pm.h"

namespace power_manager {
namespace {

constexpr char kTag[] = "power_manager";
constexpr int kMaximumCPUFrequencyMHz = 160;
constexpr int kMinimumCPUFrequencyMHz = 40;

}  // namespace

esp_err_t ConfigureAlwaysConnectedMode()
{
    const esp_pm_config_t config = {
        .max_freq_mhz = kMaximumCPUFrequencyMHz,
        .min_freq_mhz = kMinimumCPUFrequencyMHz,
        .light_sleep_enable = true,
    };
    const esp_err_t result = esp_pm_configure(&config);
    if (result == ESP_OK) {
        ESP_LOGI(kTag,
                 "动态降频=%d-%d MHz 自动Light-sleep=启用 BLE连接=保持",
                 kMinimumCPUFrequencyMHz,
                 kMaximumCPUFrequencyMHz);
    }
    return result;
}

esp_err_t DisableAutomaticLightSleepForDeepSleep()
{
    esp_pm_config_t config = {};
    esp_err_t result = esp_pm_get_configuration(&config);
    if (result != ESP_OK || !config.light_sleep_enable) {
        return result;
    }
    config.light_sleep_enable = false;
    result = esp_pm_configure(&config);
    if (result == ESP_OK) {
        ESP_LOGI(kTag, "夜间Deep-sleep前已关闭自动Light-sleep并清理其定时器");
    }
    return result;
}

}  // namespace power_manager
