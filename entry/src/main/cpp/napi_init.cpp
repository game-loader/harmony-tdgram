// NAPI bridge between ArkTS and TDLib's JSON interface.
//
// One background thread calls td_receive() and hands the results to the JS
// thread in batches through a threadsafe function, so the UI thread never
// blocks on TDLib and a burst of updates costs one JS hop instead of hundreds.
#include <atomic>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include <hilog/log.h>
#include <napi/native_api.h>
#include <td/telegram/td_json_client.h>

#include "third_party/qrcodegen/qrcodegen.hpp"

#undef LOG_TAG
#define LOG_TAG "tdbridge"

namespace {
constexpr double kReceiveTimeoutS = 1.0;
constexpr size_t kMaxBatch = 64;

std::mutex g_mutex;
napi_threadsafe_function g_onBatch = nullptr; // guarded by g_mutex
std::thread g_receiver;
std::atomic<bool> g_receiverStarted{false};

std::string GetString(napi_env env, napi_value v) {
    size_t len = 0;
    napi_get_value_string_utf8(env, v, nullptr, 0, &len);
    std::string s(len, '\0');
    napi_get_value_string_utf8(env, v, s.data(), len + 1, &len);
    return s;
}

void CallBatchJs(napi_env env, napi_value jsCb, void *, void *data) {
    auto *batch = static_cast<std::vector<std::string> *>(data);
    if (env && jsCb) {
        napi_value arr;
        napi_create_array_with_length(env, batch->size(), &arr);
        for (size_t i = 0; i < batch->size(); ++i) {
            napi_value s;
            napi_create_string_utf8(env, (*batch)[i].data(), (*batch)[i].size(), &s);
            napi_set_element(env, arr, static_cast<uint32_t>(i), s);
        }
        napi_value undefined;
        napi_get_undefined(env, &undefined);
        napi_call_function(env, undefined, jsCb, 1, &arr, nullptr);
    }
    delete batch;
}

void Deliver(std::vector<std::string> *batch) {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (!g_onBatch || napi_call_threadsafe_function(g_onBatch, batch, napi_tsfn_blocking) != napi_ok) {
        delete batch;
    }
}

void ReceiveLoop() {
    while (true) {
        // td_receive() returns a pointer valid until the next call, so copy it.
        const char *first = td_receive(kReceiveTimeoutS);
        if (!first) continue;
        auto *batch = new std::vector<std::string>();
        batch->emplace_back(first);
        // Drain whatever is already queued without waiting.
        while (batch->size() < kMaxBatch) {
            const char *next = td_receive(0);
            if (!next) break;
            batch->emplace_back(next);
        }
        Deliver(batch);
    }
}

napi_value CreateClient(napi_env env, napi_callback_info) {
    napi_value result;
    napi_create_int32(env, td_create_client_id(), &result);
    return result;
}

napi_value Send(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t clientId = 0;
    napi_get_value_int32(env, args[0], &clientId);
    td_send(clientId, GetString(env, args[1]).c_str());
    return nullptr;
}

napi_value Execute(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value arg;
    napi_get_cb_info(env, info, &argc, &arg, nullptr, nullptr);
    const char *res = td_execute(GetString(env, arg).c_str());
    napi_value result;
    napi_create_string_utf8(env, res ? res : "", NAPI_AUTO_LENGTH, &result);
    return result;
}

// qrMatrix(text) -> { size, modules } where modules is a row-major 0/1 string.
napi_value QrMatrix(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value arg;
    napi_get_cb_info(env, info, &argc, &arg, nullptr, nullptr);
    std::string text = GetString(env, arg);
    qrcodegen::QrCode qr = qrcodegen::QrCode::encodeText(text.c_str(), qrcodegen::QrCode::Ecc::MEDIUM);
    int size = qr.getSize();
    std::string modules(static_cast<size_t>(size * size), '0');
    for (int y = 0; y < size; ++y) {
        for (int x = 0; x < size; ++x) {
            if (qr.getModule(x, y)) modules[static_cast<size_t>(y * size + x)] = '1';
        }
    }
    napi_value result, sizeVal, modVal;
    napi_create_object(env, &result);
    napi_create_int32(env, size, &sizeVal);
    napi_create_string_utf8(env, modules.data(), modules.size(), &modVal);
    napi_set_named_property(env, result, "size", sizeVal);
    napi_set_named_property(env, result, "modules", modVal);
    return result;
}

napi_value StartReceive(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value cb;
    napi_get_cb_info(env, info, &argc, &cb, nullptr, nullptr);
    napi_value name;
    napi_create_string_utf8(env, "tdReceive", NAPI_AUTO_LENGTH, &name);
    napi_threadsafe_function fn = nullptr;
    napi_create_threadsafe_function(env, cb, nullptr, name, 256, 1, nullptr, nullptr, nullptr, CallBatchJs, &fn);
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        if (g_onBatch) napi_release_threadsafe_function(g_onBatch, napi_tsfn_abort);
        g_onBatch = fn;
    }
    if (!g_receiverStarted.exchange(true)) {
        g_receiver = std::thread(ReceiveLoop);
        g_receiver.detach();
    }
    return nullptr;
}
} // namespace

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
    // TDLib logs go to its own sink; keep only warnings and errors.
    td_execute(R"({"@type":"setLogVerbosityLevel","new_verbosity_level":1})");
    napi_property_descriptor desc[] = {
        {"createClient", nullptr, CreateClient, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"send", nullptr, Send, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"execute", nullptr, Execute, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"qrMatrix", nullptr, QrMatrix, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"startReceive", nullptr, StartReceive, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module tdbridgeModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "tdbridge",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterTdbridgeModule(void) { napi_module_register(&tdbridgeModule); }
