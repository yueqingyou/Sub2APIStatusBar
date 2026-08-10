#include "pcf85063.h"

#include <cstddef>
#include <cstdint>

#include "driver/i2c_master.h"

#include "board_config.h"

namespace pcf85063 {
namespace {

constexpr i2c_port_num_t kI2CPort = I2C_NUM_0;
constexpr uint16_t kAddress = 0x51;
constexpr uint32_t kI2CClockHz = 100'000;
constexpr int kTimeoutMilliseconds = 50;

constexpr uint8_t kControl1Register = 0x00;
constexpr uint8_t kControl2Register = 0x01;
constexpr uint8_t kSecondsRegister = 0x04;
constexpr uint8_t kSecondAlarmRegister = 0x0B;
constexpr uint8_t kTimerModeRegister = 0x11;
constexpr uint8_t kControl1CapacitanceMask = 0x01;
constexpr uint8_t kControl2AlarmInterruptMask = 0x80;
constexpr uint8_t kClockOutputMask = 0x07;
constexpr uint8_t kAlarmDisabledMask = 0x80;
constexpr uint8_t kOscillatorStoppedMask = 0x80;

struct Device {
    i2c_master_bus_handle_t bus = nullptr;
    i2c_master_dev_handle_t handle = nullptr;
};

uint8_t ToBCD(uint8_t value)
{
    return static_cast<uint8_t>(((value / 10U) << 4U) | (value % 10U));
}

uint8_t FromBCD(uint8_t value)
{
    return static_cast<uint8_t>(((value >> 4U) * 10U) + (value & 0x0FU));
}

bool IsBCD(uint8_t value)
{
    return (value & 0x0FU) <= 9U && ((value >> 4U) & 0x0FU) <= 9U;
}

bool IsLeapYear(uint16_t year)
{
    return year % 4U == 0U && (year % 100U != 0U || year % 400U == 0U);
}

uint8_t DaysInMonth(uint16_t year, uint8_t month)
{
    constexpr uint8_t days[] = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
    if (month == 0 || month > 12) {
        return 0;
    }
    if (month == 2 && IsLeapYear(year)) {
        return 29;
    }
    return days[month - 1];
}

bool IsValid(const DateTime &date_time)
{
    return date_time.year >= 2000
        && date_time.year <= 2099
        && date_time.month >= 1
        && date_time.month <= 12
        && date_time.day >= 1
        && date_time.day <= DaysInMonth(date_time.year, date_time.month)
        && date_time.weekday <= 6
        && date_time.hour <= 23
        && date_time.minute <= 59
        && date_time.second <= 59;
}

esp_err_t Open(Device *device)
{
    i2c_master_bus_config_t bus_config = {};
    bus_config.i2c_port = kI2CPort;
    bus_config.sda_io_num = board::kI2CSdaPin;
    bus_config.scl_io_num = board::kI2CSclPin;
    bus_config.clk_source = I2C_CLK_SRC_DEFAULT;
    bus_config.glitch_ignore_cnt = 7;
    esp_err_t result = i2c_new_master_bus(&bus_config, &device->bus);
    if (result != ESP_OK) {
        return result;
    }

    i2c_device_config_t device_config = {};
    device_config.dev_addr_length = I2C_ADDR_BIT_LEN_7;
    device_config.device_address = kAddress;
    device_config.scl_speed_hz = kI2CClockHz;
    result = i2c_master_bus_add_device(device->bus, &device_config, &device->handle);
    if (result != ESP_OK) {
        i2c_del_master_bus(device->bus);
        device->bus = nullptr;
    }
    return result;
}

esp_err_t Close(Device *device, esp_err_t result)
{
    if (device->handle != nullptr) {
        const esp_err_t remove_result = i2c_master_bus_rm_device(device->handle);
        if (result == ESP_OK) {
            result = remove_result;
        }
        device->handle = nullptr;
    }
    if (device->bus != nullptr) {
        const esp_err_t delete_result = i2c_del_master_bus(device->bus);
        if (result == ESP_OK) {
            result = delete_result;
        }
        device->bus = nullptr;
    }
    return result;
}

esp_err_t Read(Device *device, uint8_t first_register, uint8_t *bytes, size_t length)
{
    return i2c_master_transmit_receive(
        device->handle,
        &first_register,
        sizeof(first_register),
        bytes,
        length,
        kTimeoutMilliseconds);
}

esp_err_t Write(Device *device, const uint8_t *bytes, size_t length)
{
    return i2c_master_transmit(device->handle, bytes, length, kTimeoutMilliseconds);
}

esp_err_t ConfigureNormalClockMode(Device *device)
{
    uint8_t control1 = 0;
    esp_err_t result = Read(device, kControl1Register, &control1, sizeof(control1));
    if (result != ESP_OK) {
        return result;
    }
    const uint8_t normal_control1 = static_cast<uint8_t>(
        control1 & kControl1CapacitanceMask);
    if (normal_control1 == control1) {
        return ESP_OK;
    }
    const uint8_t write[] = {kControl1Register, normal_control1};
    return Write(device, write, sizeof(write));
}

esp_err_t DisableOtherInterruptSources(Device *device)
{
    const uint8_t write[] = {kTimerModeRegister, 0x00};
    return Write(device, write, sizeof(write));
}

esp_err_t ConfigureControl2(Device *device, bool alarm_enabled)
{
    const uint8_t control2 = static_cast<uint8_t>(
        kClockOutputMask | (alarm_enabled ? kControl2AlarmInterruptMask : 0U));
    const uint8_t write[] = {kControl2Register, control2};
    return Write(device, write, sizeof(write));
}

}  // namespace

esp_err_t DisableClockOutput()
{
    Device device;
    esp_err_t result = Open(&device);
    if (result == ESP_OK) {
        uint8_t control2 = 0;
        result = Read(&device, kControl2Register, &control2, sizeof(control2));
        if (result == ESP_OK && (control2 & kClockOutputMask) != kClockOutputMask) {
            const uint8_t write[] = {
                kControl2Register,
                static_cast<uint8_t>(control2 | kClockOutputMask),
            };
            result = Write(&device, write, sizeof(write));
        }
    }
    return Close(&device, result);
}

esp_err_t SetDateTime(const DateTime &date_time)
{
    if (!IsValid(date_time)) {
        return ESP_ERR_INVALID_ARG;
    }

    Device device;
    esp_err_t result = Open(&device);
    if (result == ESP_OK) {
        result = ConfigureNormalClockMode(&device);
        if (result == ESP_OK) {
            const uint8_t time_write[] = {
                kSecondsRegister,
                ToBCD(date_time.second),
                ToBCD(date_time.minute),
                ToBCD(date_time.hour),
                ToBCD(date_time.day),
                date_time.weekday,
                ToBCD(date_time.month),
                ToBCD(static_cast<uint8_t>(date_time.year - 2000U)),
            };
            result = Write(&device, time_write, sizeof(time_write));
        }
    }
    return Close(&device, result);
}

esp_err_t ReadDateTime(DateTime *date_time)
{
    if (date_time == nullptr) {
        return ESP_ERR_INVALID_ARG;
    }

    Device device;
    uint8_t bytes[7] = {};
    esp_err_t result = Open(&device);
    if (result == ESP_OK) {
        result = Read(&device, kSecondsRegister, bytes, sizeof(bytes));
    }
    result = Close(&device, result);
    if (result != ESP_OK) {
        return result;
    }
    if ((bytes[0] & kOscillatorStoppedMask) != 0) {
        return ESP_ERR_INVALID_STATE;
    }
    if (!IsBCD(static_cast<uint8_t>(bytes[0] & 0x7FU))
        || !IsBCD(static_cast<uint8_t>(bytes[1] & 0x7FU))
        || !IsBCD(static_cast<uint8_t>(bytes[2] & 0x3FU))
        || !IsBCD(static_cast<uint8_t>(bytes[3] & 0x3FU))
        || !IsBCD(static_cast<uint8_t>(bytes[5] & 0x1FU))
        || !IsBCD(bytes[6])) {
        return ESP_ERR_INVALID_RESPONSE;
    }

    const DateTime decoded = {
        .year = static_cast<uint16_t>(2000U + FromBCD(bytes[6])),
        .month = FromBCD(static_cast<uint8_t>(bytes[5] & 0x1FU)),
        .day = FromBCD(static_cast<uint8_t>(bytes[3] & 0x3FU)),
        .weekday = static_cast<uint8_t>(bytes[4] & 0x07U),
        .hour = FromBCD(static_cast<uint8_t>(bytes[2] & 0x3FU)),
        .minute = FromBCD(static_cast<uint8_t>(bytes[1] & 0x7FU)),
        .second = FromBCD(static_cast<uint8_t>(bytes[0] & 0x7FU)),
    };
    if (!IsValid(decoded)) {
        return ESP_ERR_INVALID_RESPONSE;
    }
    *date_time = decoded;
    return ESP_OK;
}

esp_err_t ConfigureDailyAlarm(uint8_t hour, uint8_t minute, uint8_t second)
{
    if (hour > 23 || minute > 59 || second > 59) {
        return ESP_ERR_INVALID_ARG;
    }

    Device device;
    esp_err_t result = Open(&device);
    if (result == ESP_OK) {
        result = ConfigureNormalClockMode(&device);
    }
    if (result == ESP_OK) {
        result = DisableOtherInterruptSources(&device);
    }
    if (result == ESP_OK) {
        const uint8_t alarm_write[] = {
            kSecondAlarmRegister,
            ToBCD(second),
            ToBCD(minute),
            ToBCD(hour),
            kAlarmDisabledMask,
            kAlarmDisabledMask,
        };
        result = Write(&device, alarm_write, sizeof(alarm_write));
        if (result == ESP_OK) {
            result = ConfigureControl2(&device, true);
        }
    }
    return Close(&device, result);
}

esp_err_t DisableAlarm()
{
    Device device;
    esp_err_t result = Open(&device);
    if (result == ESP_OK) {
        result = DisableOtherInterruptSources(&device);
    }
    if (result == ESP_OK) {
        const uint8_t alarm_write[] = {
            kSecondAlarmRegister,
            kAlarmDisabledMask,
            kAlarmDisabledMask,
            kAlarmDisabledMask,
            kAlarmDisabledMask,
            kAlarmDisabledMask,
        };
        result = Write(&device, alarm_write, sizeof(alarm_write));
        if (result == ESP_OK) {
            result = ConfigureControl2(&device, false);
        }
    }
    return Close(&device, result);
}

esp_err_t ClearAlarmFlag()
{
    Device device;
    esp_err_t result = Open(&device);
    if (result == ESP_OK) {
        result = DisableOtherInterruptSources(&device);
    }
    if (result == ESP_OK) {
        uint8_t control2 = 0;
        result = Read(&device, kControl2Register, &control2, sizeof(control2));
        if (result == ESP_OK) {
            const uint8_t write[] = {
                kControl2Register,
                static_cast<uint8_t>(
                    (control2 & kControl2AlarmInterruptMask) | kClockOutputMask),
            };
            result = Write(&device, write, sizeof(write));
        }
    }
    return Close(&device, result);
}

}  // namespace pcf85063
