idf_component_register(
    SRCS
        "battery_monitor.cpp"
        "ble_link.c"
        "board_power.cpp"
        "firmware_update.c"
        "main.cpp"
        "monitor_events.cpp"
        "night_sleep.cpp"
        "pcf85063.cpp"
        "power_manager.cpp"
    REQUIRES
        app_update
        bt
        esp_driver_i2c
        esp_adc
        esp_app_format
        esp_partition
        esp_pm
        esp_system
        esp_timer
        heap
        mbedtls
        nvs_flash
        u8g2_st7305
    INCLUDE_DIRS "."
)

string(REPLACE "." ";" MONITOR_FIRMWARE_VERSION_PARTS "${MONITOR_FIRMWARE_VERSION}")
foreach(MONITOR_FIRMWARE_VERSION_PART IN LISTS MONITOR_FIRMWARE_VERSION_PARTS)
    if(MONITOR_FIRMWARE_VERSION_PART GREATER 255)
        message(FATAL_ERROR
            "MONITOR_FIRMWARE_VERSION components must fit in one byte: ${MONITOR_FIRMWARE_VERSION}")
    endif()
endforeach()
list(GET MONITOR_FIRMWARE_VERSION_PARTS 0 MONITOR_FIRMWARE_VERSION_MAJOR)
list(GET MONITOR_FIRMWARE_VERSION_PARTS 1 MONITOR_FIRMWARE_VERSION_MINOR)
list(GET MONITOR_FIRMWARE_VERSION_PARTS 2 MONITOR_FIRMWARE_VERSION_PATCH)
target_compile_definitions(${COMPONENT_LIB} PRIVATE
    MONITOR_FIRMWARE_VERSION_MAJOR=${MONITOR_FIRMWARE_VERSION_MAJOR}
    MONITOR_FIRMWARE_VERSION_MINOR=${MONITOR_FIRMWARE_VERSION_MINOR}
    MONITOR_FIRMWARE_VERSION_PATCH=${MONITOR_FIRMWARE_VERSION_PATCH}
    MONITOR_FIRMWARE_VERSION_STRING="${MONITOR_FIRMWARE_VERSION}"
)
