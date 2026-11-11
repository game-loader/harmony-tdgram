cmake_minimum_required(VERSION 3.5.0)
project(tdbridge)

set(CMAKE_CXX_STANDARD 17)

# libtdjson.so is cross-compiled separately (see scripts/build-tdlib-ohos.sh)
# and shipped from entry/libs/<abi>/.
add_library(tdjson SHARED IMPORTED)
set_target_properties(tdjson PROPERTIES
    IMPORTED_LOCATION ${CMAKE_CURRENT_SOURCE_DIR}/../../../libs/${OHOS_ARCH}/libtdjson.so)

# Static Ogg/Opus libraries from scripts/build-audio-ohos.sh.
set(PREBUILT ${CMAKE_CURRENT_SOURCE_DIR}/prebuilt/${OHOS_ARCH})
foreach(lib opusenc opusfile opus ogg)
    add_library(${lib} STATIC IMPORTED)
    set_target_properties(${lib} PROPERTIES IMPORTED_LOCATION ${PREBUILT}/lib${lib}.a)
endforeach()

add_library(tdbridge SHARED napi_init.cpp media.cpp stream.cpp third_party/qrcodegen/qrcodegen.cpp)
target_include_directories(tdbridge PRIVATE include ${PREBUILT}/include ${PREBUILT}/include/opus)
target_link_libraries(tdbridge PUBLIC tdjson opusenc opusfile opus ogg z
    libace_napi.z.so libhilog_ndk.z.so)
