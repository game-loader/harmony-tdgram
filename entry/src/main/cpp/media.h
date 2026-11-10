#pragma once

#include <napi/native_api.h>

// Adds decodeOpusToWav, gunzipToString and the encoder* functions to exports.
void RegisterMedia(napi_env env, napi_value exports);
