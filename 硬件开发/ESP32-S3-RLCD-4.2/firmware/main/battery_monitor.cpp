#include "battery_monitor.h"

#include <algorithm>

#include "esp_adc/adc_cali.h"
#include "esp_adc/adc_cali_scheme.h"
#include "esp_adc/adc_oneshot.h"
#include "soc/adc_channel.h"

#include "board_config.h"

namespace battery_monitor {
namespace {

constexpr adc_unit_t kADCUnit = ADC_UNIT_1;
constexpr adc_channel_t kADCChannel = ADC_CHANNEL_3;
constexpr adc_atten_t kADCAttenuation = ADC_ATTEN_DB_12;
constexpr int kVoltageDividerRatio = 3;
constexpr int kWarmupSampleCount = 4;
constexpr int kAverageSampleCount = 16;
constexpr uint16_t kPresentThresholdMillivolts = 1'000;

Snapshot g_snapshot;

static_assert(ADC1_CHANNEL_3_GPIO_NUM == board::kBatteryADCPin);

void StoreSnapshot(Snapshot next)
{
    const bool display_changed = next.state != g_snapshot.state
        || next.voltage_millivolts != g_snapshot.voltage_millivolts
        || next.percentage != g_snapshot.percentage;
    next.revision = g_snapshot.revision + (display_changed ? 1U : 0U);
    g_snapshot = next;
}

esp_err_t StoreUnavailable(esp_err_t result)
{
    StoreSnapshot(Snapshot {});
    return result;
}

esp_err_t DeleteADC(
    adc_oneshot_unit_handle_t unit_handle,
    adc_cali_handle_t calibration_handle,
    esp_err_t result)
{
    const esp_err_t calibration_result =
        adc_cali_delete_scheme_curve_fitting(calibration_handle);
    const esp_err_t unit_result = adc_oneshot_del_unit(unit_handle);
    if (result != ESP_OK) {
        return result;
    }
    if (unit_result != ESP_OK) {
        return unit_result;
    }
    return calibration_result;
}

void StoreMeasurement(uint16_t voltage_millivolts)
{
    Snapshot next;
    if (voltage_millivolts < kPresentThresholdMillivolts) {
        next.state = State::kNotPresent;
    } else {
        next.state = State::kAvailable;
        next.voltage_millivolts =
            static_cast<uint16_t>(((voltage_millivolts + 5U) / 10U) * 10U);
        next.percentage = EstimatePercentage(next.voltage_millivolts);
    }

    StoreSnapshot(next);
}

}  // namespace

esp_err_t Sample()
{
    adc_oneshot_unit_handle_t unit_handle = nullptr;
    adc_oneshot_unit_init_cfg_t unit_config = {
        .unit_id = kADCUnit,
        .clk_src = ADC_RTC_CLK_SRC_DEFAULT,
        .ulp_mode = ADC_ULP_MODE_DISABLE,
    };
    esp_err_t result = adc_oneshot_new_unit(&unit_config, &unit_handle);
    if (result != ESP_OK) {
        return StoreUnavailable(result);
    }

    adc_oneshot_chan_cfg_t channel_config = {
        .atten = kADCAttenuation,
        .bitwidth = ADC_BITWIDTH_DEFAULT,
    };
    result = adc_oneshot_config_channel(unit_handle, kADCChannel, &channel_config);
    if (result != ESP_OK) {
        adc_oneshot_del_unit(unit_handle);
        return StoreUnavailable(result);
    }

    adc_cali_handle_t calibration_handle = nullptr;
    adc_cali_curve_fitting_config_t calibration_config = {
        .unit_id = kADCUnit,
        .chan = kADCChannel,
        .atten = kADCAttenuation,
        .bitwidth = ADC_BITWIDTH_DEFAULT,
    };
    result = adc_cali_create_scheme_curve_fitting(
        &calibration_config,
        &calibration_handle);
    if (result != ESP_OK) {
        adc_oneshot_del_unit(unit_handle);
        return StoreUnavailable(result);
    }

    int raw = 0;
    for (int sample = 0; sample < kWarmupSampleCount; ++sample) {
        result = adc_oneshot_read(unit_handle, kADCChannel, &raw);
        if (result != ESP_OK) {
            return StoreUnavailable(DeleteADC(unit_handle, calibration_handle, result));
        }
    }

    int64_t raw_total = 0;
    for (int sample = 0; sample < kAverageSampleCount; ++sample) {
        result = adc_oneshot_read(unit_handle, kADCChannel, &raw);
        if (result != ESP_OK) {
            return StoreUnavailable(DeleteADC(unit_handle, calibration_handle, result));
        }
        raw_total += raw;
    }

    const int average_raw = static_cast<int>(
        (raw_total + (kAverageSampleCount / 2)) / kAverageSampleCount);
    int divided_voltage_millivolts = 0;
    result = adc_cali_raw_to_voltage(
        calibration_handle,
        average_raw,
        &divided_voltage_millivolts);
    const esp_err_t final_result = DeleteADC(unit_handle, calibration_handle, result);
    if (final_result != ESP_OK) {
        return StoreUnavailable(final_result);
    }

    const int battery_voltage_millivolts =
        std::max(0, divided_voltage_millivolts) * kVoltageDividerRatio;
    StoreMeasurement(static_cast<uint16_t>(std::min(
        battery_voltage_millivolts,
        static_cast<int>(UINT16_MAX))));
    return ESP_OK;
}

Snapshot GetSnapshot()
{
    return g_snapshot;
}

}  // namespace battery_monitor
