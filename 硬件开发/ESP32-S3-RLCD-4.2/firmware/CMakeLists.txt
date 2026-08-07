cmake_minimum_required(VERSION 3.16)

file(GLOB GENERATED_CONFLICT_ENTRIES
    LIST_DIRECTORIES true
    "${CMAKE_CURRENT_SOURCE_DIR}/managed_components/* [0-9]*")
if(GENERATED_CONFLICT_ENTRIES)
    list(GET GENERATED_CONFLICT_ENTRIES 0 FIRST_CONFLICT_COPY)
    message(FATAL_ERROR
        "managed_components contains a conflict-copy entry: ${FIRST_CONFLICT_COPY}. "
        "Move the generated directory to tmp and let ESP-IDF restore it from dependencies.lock.")
endif()

include($ENV{IDF_PATH}/tools/cmake/project.cmake)

set(MONITOR_FIRMWARE_VERSION "0.7.0" CACHE STRING "Hardware monitor firmware version")
if(NOT MONITOR_FIRMWARE_VERSION MATCHES "^[0-9]+\\.[0-9]+\\.[0-9]+$")
    message(FATAL_ERROR
        "MONITOR_FIRMWARE_VERSION must contain three numeric components: ${MONITOR_FIRMWARE_VERSION}")
endif()
set(PROJECT_VER "${MONITOR_FIRMWARE_VERSION}")
project(tokenrouter_monitor)
