#pragma once

#include "esp_err.h"

namespace power_manager {

esp_err_t ConfigureAlwaysConnectedMode();
esp_err_t DisableAutomaticLightSleepForDeepSleep();

}  // namespace power_manager
