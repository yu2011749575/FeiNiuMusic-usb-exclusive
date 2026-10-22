cmake_minimum_required(VERSION 3.22.1)
project(usb_audio_exclusive)

add_library(
        usb_uac_output
        SHARED
        usb_uac_output.cpp)

find_library(log-lib log)

target_link_libraries(usb_uac_output ${log-lib})
target_compile_features(usb_uac_output PRIVATE cxx_std_17)
# 16KB 页兼容（Android 15+ / Play 2025-11 起要求）：ELF LOAD 段按 16KB 对齐
target_link_options(usb_uac_output PRIVATE "-Wl,-z,max-page-size=16384")
