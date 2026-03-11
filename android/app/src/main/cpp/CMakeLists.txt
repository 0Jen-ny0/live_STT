cmake_minimum_required(VERSION 3.22.1)

project(whisper_jni)

set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(WHISPER_CPP_DIR ${CMAKE_CURRENT_SOURCE_DIR}/whisper)

set(WHISPER_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(WHISPER_SDL2 OFF CACHE BOOL "" FORCE)

# Keep Android build simple: CPU-only
set(GGML_VULKAN OFF CACHE BOOL "" FORCE)
set(GGML_CUDA OFF CACHE BOOL "" FORCE)
set(GGML_METAL OFF CACHE BOOL "" FORCE)
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)

add_subdirectory(${WHISPER_CPP_DIR} whispercpp_build)

add_library(
    whisper_jni
    SHARED
    whisper_jni.cpp
)

target_include_directories(
    whisper_jni
    PRIVATE
    ${WHISPER_CPP_DIR}/include
)

find_library(log-lib log)

target_link_libraries(
    whisper_jni
    whisper
    ${log-lib}
)