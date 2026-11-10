cmake_minimum_required(VERSION 3.5.0)
project(tdbridge)

set(CMAKE_CXX_STANDARD 17)

# libtdjson.so is cross-compiled separately (see scripts/build-tdlib-ohos.sh)
# and shipped from entry/libs/<abi>/.
add_library(tdjson SHARED IMPORTED)
set_target_properties(tdjson PROPERTIES
    IMPORTED_LOCATION ${CMAKE_CURRENT_SOURCE_DIR}/../../../libs/${OHOS_ARCH}/libtdjson.so)

add_library(tdbridge SHARED napi_init.cpp third_party/qrcodegen/qrcodegen.cpp)
target_include_directories(tdbridge PRIVATE include)
target_link_libraries(tdbridge PUBLIC tdjson libace_napi.z.so libhilog_ndk.z.so)
