#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

#define FIRMWARE_UPDATE_PROTOCOL_VERSION 1
#define FIRMWARE_UPDATE_SHA256_LENGTH 32

typedef enum {
    FIRMWARE_UPDATE_STATE_IDLE = 0,
    FIRMWARE_UPDATE_STATE_RECEIVING = 1,
    FIRMWARE_UPDATE_STATE_VERIFYING = 2,
    FIRMWARE_UPDATE_STATE_RESTARTING = 3,
    FIRMWARE_UPDATE_STATE_FAILED = 4,
} firmware_update_state_t;

typedef enum {
    FIRMWARE_UPDATE_ERROR_NONE = 0,
    FIRMWARE_UPDATE_ERROR_INVALID_STATE = 1,
    FIRMWARE_UPDATE_ERROR_NO_PARTITION = 2,
    FIRMWARE_UPDATE_ERROR_IMAGE_TOO_LARGE = 3,
    FIRMWARE_UPDATE_ERROR_BEGIN_FAILED = 4,
    FIRMWARE_UPDATE_ERROR_WRITE_FAILED = 5,
    FIRMWARE_UPDATE_ERROR_SIZE_MISMATCH = 6,
    FIRMWARE_UPDATE_ERROR_HASH_MISMATCH = 7,
    FIRMWARE_UPDATE_ERROR_INVALID_IMAGE = 8,
    FIRMWARE_UPDATE_ERROR_VERSION_MISMATCH = 9,
    FIRMWARE_UPDATE_ERROR_BOOT_SELECTION_FAILED = 10,
    FIRMWARE_UPDATE_ERROR_DISCONNECTED = 11,
} firmware_update_error_t;

typedef struct {
    firmware_update_state_t state;
    firmware_update_error_t error;
    uint32_t image_size;
    uint32_t received_bytes;
    uint8_t progress_percent;
    uint32_t revision;
} firmware_update_snapshot_t;

esp_err_t firmware_update_confirm_running_image(void);
esp_err_t firmware_update_start(
    uint32_t image_size,
    uint8_t version_major,
    uint8_t version_minor,
    uint8_t version_patch,
    const uint8_t expected_sha256[FIRMWARE_UPDATE_SHA256_LENGTH]);
esp_err_t firmware_update_write(const uint8_t *data, size_t length);
esp_err_t firmware_update_finish(void);
void firmware_update_abort(firmware_update_error_t error);
void firmware_update_tick(void);
firmware_update_snapshot_t firmware_update_snapshot(void);
bool firmware_update_is_active(void);
const char *firmware_update_state_name(firmware_update_state_t state);

#ifdef __cplusplus
}
#endif
