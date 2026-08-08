#pragma once

#include <cstdint>

#include "esp_err.h"

namespace battery_monitor {

enum class State : uint8_t {
    kUnavailable,
    kNotPresent,
    kAvailable,
};

struct Snapshot {
    State state = State::kUnavailable;
    uint16_t voltage_millivolts = 0;
    uint8_t percentage = 0;
    uint32_t revision = 0;
};

inline constexpr uint16_t kEmptyVoltageMillivolts = 2'500;
inline constexpr uint16_t kFullVoltageMillivolts = 4'200;

constexpr uint8_t EstimatePercentage(uint16_t voltage_millivolts)
{
    if (voltage_millivolts <= kEmptyVoltageMillivolts) {
        return 0;
    }
    if (voltage_millivolts >= kFullVoltageMillivolts) {
        return 100;
    }
    return static_cast<uint8_t>(
        (static_cast<uint32_t>(voltage_millivolts - kEmptyVoltageMillivolts) * 100U)
        / (kFullVoltageMillivolts - kEmptyVoltageMillivolts));
}

esp_err_t Sample();
Snapshot GetSnapshot();

static_assert(EstimatePercentage(2'400) == 0);
static_assert(EstimatePercentage(2'500) == 0);
static_assert(EstimatePercentage(3'350) == 50);
static_assert(EstimatePercentage(4'200) == 100);
static_assert(EstimatePercentage(4'300) == 100);

}  // namespace battery_monitor
