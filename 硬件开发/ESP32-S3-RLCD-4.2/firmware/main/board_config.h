#pragma once

#include "driver/gpio.h"

namespace board {

inline constexpr int kDisplayWidth = 400;
inline constexpr int kDisplayHeight = 300;

inline constexpr gpio_num_t kDisplayDcPin = GPIO_NUM_5;
inline constexpr gpio_num_t kDisplayCsPin = GPIO_NUM_40;
inline constexpr gpio_num_t kDisplayClockPin = GPIO_NUM_11;
inline constexpr gpio_num_t kDisplayMosiPin = GPIO_NUM_12;
inline constexpr gpio_num_t kDisplayResetPin = GPIO_NUM_41;
inline constexpr gpio_num_t kKeyPin = GPIO_NUM_18;

}  // namespace board
