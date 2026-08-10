#include "board_power.h"

#include <cstdint>

#include "driver/i2c_master.h"
#include "esp_log.h"
#include "esp_rom_sys.h"

#include "board_config.h"
#include "pcf85063.h"

namespace board_power {
namespace {

constexpr char kTag[] = "board_power";
constexpr i2c_port_num_t kI2CPort = I2C_NUM_0;
constexpr uint32_t kI2CClockHz = 100'000;
constexpr int kI2CTimeoutMilliseconds = 50;
constexpr uint16_t kSHTC3Address = 0x70;
constexpr uint32_t kSHTC3WakeDelayMicroseconds = 240;

esp_err_t AddDevice(
    i2c_master_bus_handle_t bus,
    uint16_t address,
    i2c_master_dev_handle_t *device)
{
    i2c_device_config_t config = {};
    config.dev_addr_length = I2C_ADDR_BIT_LEN_7;
    config.device_address = address;
    config.scl_speed_hz = kI2CClockHz;
    return i2c_master_bus_add_device(bus, &config, device);
}

esp_err_t RemoveDevice(i2c_master_dev_handle_t device, esp_err_t result)
{
    const esp_err_t remove_result = i2c_master_bus_rm_device(device);
    return result == ESP_OK ? remove_result : result;
}

esp_err_t PutSHTC3ToSleep(i2c_master_bus_handle_t bus)
{
    i2c_master_dev_handle_t device = nullptr;
    esp_err_t result = AddDevice(bus, kSHTC3Address, &device);
    if (result != ESP_OK) {
        return result;
    }

    // 软重启时传感器可能仍在休眠；先唤醒再休眠可让初始化保持幂等。
    constexpr uint8_t wake_command[] = {0x35, 0x17};
    result = i2c_master_transmit(
        device,
        wake_command,
        sizeof(wake_command),
        kI2CTimeoutMilliseconds);
    if (result == ESP_OK) {
        esp_rom_delay_us(kSHTC3WakeDelayMicroseconds);
        constexpr uint8_t sleep_command[] = {0xB0, 0x98};
        result = i2c_master_transmit(
            device,
            sleep_command,
            sizeof(sleep_command),
            kI2CTimeoutMilliseconds);
    }

    result = RemoveDevice(device, result);
    if (result == ESP_OK) {
        ESP_LOGI(kTag, "SHTC3=休眠");
    }
    return result;
}

void RememberFirstError(esp_err_t result, esp_err_t *first_error)
{
    if (result != ESP_OK && *first_error == ESP_OK) {
        *first_error = result;
    }
}

}  // namespace

esp_err_t ConfigureUnusedPeripheralsForStandby()
{
    i2c_master_bus_config_t bus_config = {};
    bus_config.i2c_port = kI2CPort;
    bus_config.sda_io_num = board::kI2CSdaPin;
    bus_config.scl_io_num = board::kI2CSclPin;
    bus_config.clk_source = I2C_CLK_SRC_DEFAULT;
    bus_config.glitch_ignore_cnt = 7;

    i2c_master_bus_handle_t bus = nullptr;
    esp_err_t result = i2c_new_master_bus(&bus_config, &bus);
    if (result != ESP_OK) {
        return result;
    }

    esp_err_t first_error = ESP_OK;
    result = PutSHTC3ToSleep(bus);
    if (result != ESP_OK) {
        ESP_LOGW(kTag, "SHTC3休眠设置失败：%s", esp_err_to_name(result));
    }
    RememberFirstError(result, &first_error);

    RememberFirstError(i2c_del_master_bus(bus), &first_error);
    bus = nullptr;

    result = pcf85063::DisableClockOutput();
    if (result != ESP_OK) {
        ESP_LOGW(kTag, "PCF85063时钟输出关闭失败：%s", esp_err_to_name(result));
    } else {
        ESP_LOGI(kTag, "PCF85063_CLKOUT=关闭 RTC计时与告警寄存器=保留");
    }
    RememberFirstError(result, &first_error);
    return first_error;
}

}  // namespace board_power
