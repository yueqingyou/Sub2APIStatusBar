#include "firmware_update.h"

#include <stdio.h>
#include <string.h>

#include "esp_app_format.h"
#include "esp_log.h"
#include "esp_ota_ops.h"
#include "esp_partition.h"
#include "esp_system.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "mbedtls/sha256.h"

#define FIRMWARE_HEADER_LENGTH \
    (sizeof(esp_image_header_t) + sizeof(esp_image_segment_header_t) + sizeof(esp_app_desc_t))
#define FIRMWARE_RESTART_DELAY_US 1500000

static const char *kTag = "firmware_update";
static const char *kExpectedProjectName = "tokenrouter_monitor";

static portMUX_TYPE s_lock = portMUX_INITIALIZER_UNLOCKED;
static firmware_update_snapshot_t s_snapshot;
static esp_ota_handle_t s_update_handle;
static bool s_update_handle_active;
static const esp_partition_t *s_update_partition;
static uint8_t s_expected_sha256[FIRMWARE_UPDATE_SHA256_LENGTH];
static char s_expected_version[16];
static uint8_t s_header[FIRMWARE_HEADER_LENGTH];
static size_t s_header_length;
static bool s_header_validated;
static mbedtls_sha256_context s_sha256;
static bool s_sha256_active;
static int64_t s_restart_deadline_us;

static void update_snapshot(
    firmware_update_state_t state,
    firmware_update_error_t error,
    uint32_t image_size,
    uint32_t received_bytes,
    bool force_revision)
{
    const uint8_t progress = image_size == 0
        ? 0
        : (uint8_t)((uint64_t)received_bytes * 100U / image_size);
    const uint8_t displayed_progress = progress >= 100 ? 100 : (uint8_t)((progress / 5U) * 5U);

    portENTER_CRITICAL(&s_lock);
    const bool changed = force_revision
        || s_snapshot.state != state
        || s_snapshot.error != error
        || s_snapshot.image_size != image_size
        || s_snapshot.progress_percent != displayed_progress;
    s_snapshot.state = state;
    s_snapshot.error = error;
    s_snapshot.image_size = image_size;
    s_snapshot.received_bytes = received_bytes;
    s_snapshot.progress_percent = displayed_progress;
    if (changed) {
        ++s_snapshot.revision;
    }
    portEXIT_CRITICAL(&s_lock);
}

firmware_update_snapshot_t firmware_update_snapshot(void)
{
    firmware_update_snapshot_t snapshot;
    portENTER_CRITICAL(&s_lock);
    snapshot = s_snapshot;
    portEXIT_CRITICAL(&s_lock);
    return snapshot;
}

bool firmware_update_is_active(void)
{
    const firmware_update_state_t state = firmware_update_snapshot().state;
    return state == FIRMWARE_UPDATE_STATE_RECEIVING
        || state == FIRMWARE_UPDATE_STATE_VERIFYING
        || state == FIRMWARE_UPDATE_STATE_RESTARTING;
}

const char *firmware_update_state_name(firmware_update_state_t state)
{
    switch (state) {
    case FIRMWARE_UPDATE_STATE_IDLE:
        return "idle";
    case FIRMWARE_UPDATE_STATE_RECEIVING:
        return "receiving";
    case FIRMWARE_UPDATE_STATE_VERIFYING:
        return "verifying";
    case FIRMWARE_UPDATE_STATE_RESTARTING:
        return "restarting";
    case FIRMWARE_UPDATE_STATE_FAILED:
        return "failed";
    }
    return "unknown";
}

static void release_update_resources(bool abort_update)
{
    if (s_update_handle_active) {
        if (abort_update) {
            esp_ota_abort(s_update_handle);
        }
        s_update_handle_active = false;
    }
    if (s_sha256_active) {
        mbedtls_sha256_free(&s_sha256);
        s_sha256_active = false;
    }
    s_update_partition = NULL;
}

static esp_err_t fail_update(firmware_update_error_t error, esp_err_t result)
{
    const firmware_update_snapshot_t snapshot = firmware_update_snapshot();
    release_update_resources(true);
    update_snapshot(
        FIRMWARE_UPDATE_STATE_FAILED,
        error,
        snapshot.image_size,
        snapshot.received_bytes,
        true);
    ESP_LOGE(kTag,
             "update failed: state=%s error=%u result=%s received=%lu/%lu",
             firmware_update_state_name(snapshot.state),
             (unsigned int)error,
             esp_err_to_name(result),
             (unsigned long)snapshot.received_bytes,
             (unsigned long)snapshot.image_size);
    return result;
}

esp_err_t firmware_update_confirm_running_image(void)
{
    const esp_partition_t *running = esp_ota_get_running_partition();
    esp_ota_img_states_t state;
    const esp_err_t state_result = esp_ota_get_state_partition(running, &state);
    if (state_result == ESP_ERR_NOT_SUPPORTED || state_result == ESP_ERR_NOT_FOUND) {
        return ESP_OK;
    }
    if (state_result != ESP_OK) {
        return state_result;
    }
    if (state != ESP_OTA_IMG_PENDING_VERIFY) {
        return ESP_OK;
    }

    const esp_err_t result = esp_ota_mark_app_valid_cancel_rollback();
    if (result == ESP_OK) {
        ESP_LOGI(kTag,
                 "running OTA image confirmed: partition=%s offset=0x%lx",
                 running->label,
                 (unsigned long)running->address);
    }
    return result;
}

esp_err_t firmware_update_start(
    uint32_t image_size,
    uint8_t version_major,
    uint8_t version_minor,
    uint8_t version_patch,
    const uint8_t expected_sha256[FIRMWARE_UPDATE_SHA256_LENGTH])
{
    if (expected_sha256 == NULL || image_size == 0 || firmware_update_is_active()) {
        return fail_update(FIRMWARE_UPDATE_ERROR_INVALID_STATE, ESP_ERR_INVALID_STATE);
    }

    const esp_partition_t *partition = esp_ota_get_next_update_partition(NULL);
    if (partition == NULL) {
        return fail_update(FIRMWARE_UPDATE_ERROR_NO_PARTITION, ESP_ERR_NOT_FOUND);
    }
    if (image_size > partition->size) {
        return fail_update(FIRMWARE_UPDATE_ERROR_IMAGE_TOO_LARGE, ESP_ERR_INVALID_SIZE);
    }

    release_update_resources(true);
    memset(s_header, 0, sizeof(s_header));
    s_header_length = 0;
    s_header_validated = false;
    s_restart_deadline_us = 0;
    memcpy(s_expected_sha256, expected_sha256, sizeof(s_expected_sha256));
    snprintf(s_expected_version,
             sizeof(s_expected_version),
             "%u.%u.%u",
             (unsigned int)version_major,
             (unsigned int)version_minor,
             (unsigned int)version_patch);

    mbedtls_sha256_init(&s_sha256);
    if (mbedtls_sha256_starts(&s_sha256, 0) != 0) {
        mbedtls_sha256_free(&s_sha256);
        return fail_update(FIRMWARE_UPDATE_ERROR_BEGIN_FAILED, ESP_FAIL);
    }
    s_sha256_active = true;

    const esp_err_t result = esp_ota_begin(
        partition,
        OTA_WITH_SEQUENTIAL_WRITES,
        &s_update_handle);
    if (result != ESP_OK) {
        return fail_update(FIRMWARE_UPDATE_ERROR_BEGIN_FAILED, result);
    }
    s_update_handle_active = true;
    s_update_partition = partition;
    update_snapshot(
        FIRMWARE_UPDATE_STATE_RECEIVING,
        FIRMWARE_UPDATE_ERROR_NONE,
        image_size,
        0,
        true);
    ESP_LOGI(kTag,
             "update started: target=%s version=%s size=%lu offset=0x%lx",
             partition->label,
             s_expected_version,
             (unsigned long)image_size,
             (unsigned long)partition->address);
    return ESP_OK;
}

static esp_err_t validate_header_if_ready(void)
{
    if (s_header_validated || s_header_length < sizeof(s_header)) {
        return ESP_OK;
    }

    const esp_app_desc_t *description = (const esp_app_desc_t *)(
        s_header + sizeof(esp_image_header_t) + sizeof(esp_image_segment_header_t));
    if (description->magic_word != ESP_APP_DESC_MAGIC_WORD
        || strncmp(description->project_name,
                   kExpectedProjectName,
                   sizeof(description->project_name)) != 0) {
        return fail_update(FIRMWARE_UPDATE_ERROR_INVALID_IMAGE, ESP_ERR_OTA_VALIDATE_FAILED);
    }
    if (strncmp(description->version,
                s_expected_version,
                sizeof(description->version)) != 0) {
        ESP_LOGE(kTag,
                 "image version mismatch: image=%s expected=%s",
                 description->version,
                 s_expected_version);
        return fail_update(FIRMWARE_UPDATE_ERROR_VERSION_MISMATCH, ESP_ERR_INVALID_VERSION);
    }
    s_header_validated = true;
    ESP_LOGI(kTag,
             "image header accepted: project=%s version=%s",
             description->project_name,
             description->version);
    return ESP_OK;
}

esp_err_t firmware_update_write(const uint8_t *data, size_t length)
{
    const firmware_update_snapshot_t snapshot = firmware_update_snapshot();
    if (snapshot.state != FIRMWARE_UPDATE_STATE_RECEIVING
        || !s_update_handle_active
        || data == NULL
        || length == 0
        || length > snapshot.image_size - snapshot.received_bytes) {
        return fail_update(FIRMWARE_UPDATE_ERROR_INVALID_STATE, ESP_ERR_INVALID_ARG);
    }

    const size_t header_remaining = sizeof(s_header) - s_header_length;
    const size_t header_copy_length = length < header_remaining ? length : header_remaining;
    if (header_copy_length > 0) {
        memcpy(&s_header[s_header_length], data, header_copy_length);
        s_header_length += header_copy_length;
    }

    esp_err_t result = esp_ota_write(s_update_handle, data, length);
    if (result != ESP_OK) {
        return fail_update(FIRMWARE_UPDATE_ERROR_WRITE_FAILED, result);
    }
    if (mbedtls_sha256_update(&s_sha256, data, length) != 0) {
        return fail_update(FIRMWARE_UPDATE_ERROR_WRITE_FAILED, ESP_FAIL);
    }

    const uint32_t received = snapshot.received_bytes + (uint32_t)length;
    update_snapshot(
        FIRMWARE_UPDATE_STATE_RECEIVING,
        FIRMWARE_UPDATE_ERROR_NONE,
        snapshot.image_size,
        received,
        false);
    result = validate_header_if_ready();
    return result;
}

esp_err_t firmware_update_finish(void)
{
    firmware_update_snapshot_t snapshot = firmware_update_snapshot();
    if (snapshot.state != FIRMWARE_UPDATE_STATE_RECEIVING || !s_update_handle_active) {
        return fail_update(FIRMWARE_UPDATE_ERROR_INVALID_STATE, ESP_ERR_INVALID_STATE);
    }
    if (snapshot.received_bytes != snapshot.image_size) {
        return fail_update(FIRMWARE_UPDATE_ERROR_SIZE_MISMATCH, ESP_ERR_INVALID_SIZE);
    }
    if (!s_header_validated) {
        return fail_update(FIRMWARE_UPDATE_ERROR_INVALID_IMAGE, ESP_ERR_OTA_VALIDATE_FAILED);
    }

    update_snapshot(
        FIRMWARE_UPDATE_STATE_VERIFYING,
        FIRMWARE_UPDATE_ERROR_NONE,
        snapshot.image_size,
        snapshot.received_bytes,
        true);

    uint8_t actual_sha256[FIRMWARE_UPDATE_SHA256_LENGTH];
    if (mbedtls_sha256_finish(&s_sha256, actual_sha256) != 0) {
        return fail_update(FIRMWARE_UPDATE_ERROR_HASH_MISMATCH, ESP_FAIL);
    }
    mbedtls_sha256_free(&s_sha256);
    s_sha256_active = false;
    if (memcmp(actual_sha256, s_expected_sha256, sizeof(actual_sha256)) != 0) {
        return fail_update(FIRMWARE_UPDATE_ERROR_HASH_MISMATCH, ESP_ERR_INVALID_CRC);
    }

    esp_err_t result = esp_ota_end(s_update_handle);
    s_update_handle_active = false;
    if (result != ESP_OK) {
        s_update_partition = NULL;
        return fail_update(FIRMWARE_UPDATE_ERROR_INVALID_IMAGE, result);
    }

    result = esp_ota_set_boot_partition(s_update_partition);
    if (result != ESP_OK) {
        s_update_partition = NULL;
        return fail_update(FIRMWARE_UPDATE_ERROR_BOOT_SELECTION_FAILED, result);
    }
    s_update_partition = NULL;
    s_restart_deadline_us = esp_timer_get_time() + FIRMWARE_RESTART_DELAY_US;
    update_snapshot(
        FIRMWARE_UPDATE_STATE_RESTARTING,
        FIRMWARE_UPDATE_ERROR_NONE,
        snapshot.image_size,
        snapshot.received_bytes,
        true);
    ESP_LOGI(kTag,
             "update verified; restarting into version=%s size=%lu",
             s_expected_version,
             (unsigned long)snapshot.image_size);
    return ESP_OK;
}

void firmware_update_abort(firmware_update_error_t error)
{
    const firmware_update_snapshot_t snapshot = firmware_update_snapshot();
    if (snapshot.state != FIRMWARE_UPDATE_STATE_RECEIVING
        && snapshot.state != FIRMWARE_UPDATE_STATE_VERIFYING) {
        return;
    }
    release_update_resources(true);
    update_snapshot(
        FIRMWARE_UPDATE_STATE_FAILED,
        error,
        snapshot.image_size,
        snapshot.received_bytes,
        true);
    ESP_LOGW(kTag,
             "update aborted: error=%u received=%lu/%lu",
             (unsigned int)error,
             (unsigned long)snapshot.received_bytes,
             (unsigned long)snapshot.image_size);
}

void firmware_update_tick(void)
{
    if (firmware_update_snapshot().state != FIRMWARE_UPDATE_STATE_RESTARTING
        || s_restart_deadline_us == 0
        || esp_timer_get_time() < s_restart_deadline_us) {
        return;
    }
    ESP_LOGI(kTag, "restarting into updated firmware");
    esp_restart();
}
