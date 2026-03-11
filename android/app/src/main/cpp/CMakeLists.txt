cmake_minimum_required(VERSION 3.22)
project(offline_stt_demo)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Build whisper.cpp using its own CMakeLists
add_subdirectory(whisper)

# Build our JNI shared library
add_library(whisper_jni SHARED whisper_jni.cpp)

target_include_directories(whisper_jni PRIVATE
  whisper/include
)

target_link_libraries(whisper_jni
  whisper
  android
  log
)
