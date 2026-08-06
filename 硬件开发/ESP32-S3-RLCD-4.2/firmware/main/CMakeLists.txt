idf_component_register(
    SRCS
        "ble_link.c"
        "main.cpp"
    REQUIRES
        bt
        esp_timer
        heap
        nvs_flash
        u8g2_st7305
    INCLUDE_DIRS "."
)
