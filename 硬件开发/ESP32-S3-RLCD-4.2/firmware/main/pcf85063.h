#pragma once

#include <cstdint>

#include "esp_err.h"

namespace pcf85063 {

struct DateTime {
    uint16_t year;
    uint8_t month;
    uint8_t day;
    uint8_t weekday;
    uint8_t hour;
    uint8_t minute;
    uint8_t second;
};

esp_err_t DisableClockOutput();
esp_err_t SetDateTime(const DateTime &date_time);
esp_err_t ReadDateTime(DateTime *date_time);
esp_err_t ConfigureDailyAlarm(uint8_t hour, uint8_t minute, uint8_t second);
esp_err_t DisableAlarm();
esp_err_t ClearAlarmFlag();

}  // namespace pcf85063
