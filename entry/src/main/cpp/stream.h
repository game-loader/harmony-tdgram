#pragma once
#include <napi/native_api.h>

// Registers the loopback HTTP server that streams partially downloaded
// TDLib files to the system player (streamStart, streamOpen, ...).
void RegisterStream(napi_env env, napi_value exports);
