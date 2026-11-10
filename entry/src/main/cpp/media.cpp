// Media helpers that the system frameworks do not cover:
//  - Ogg/Opus voice notes are decoded to WAV so AVPlayer can play them.
//  - Voice recordings (PCM from AudioCapturer) are encoded to Ogg/Opus, the
//    only format Telegram accepts for voice notes, together with the 5-bit
//    waveform Telegram shows in the bubble.
//  - TGS stickers (gzip-compressed Lottie JSON) are inflated for Lottie.
// Slow work runs on napi async work threads and resolves a Promise.
#include "media.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

#include <opus/opusenc.h>
#include <opus/opusfile.h>
#include <zlib.h>

namespace {
constexpr int kOpusRate = 48000; // opusfile always decodes at 48 kHz
constexpr int kWaveformBars = 100;

std::string GetString(napi_env env, napi_value v) {
    size_t len = 0;
    napi_get_value_string_utf8(env, v, nullptr, 0, &len);
    std::string s(len, '\0');
    napi_get_value_string_utf8(env, v, s.data(), len + 1, &len);
    return s;
}

void Put16(FILE *f, uint16_t v) {
    uint8_t b[2] = {static_cast<uint8_t>(v), static_cast<uint8_t>(v >> 8)};
    fwrite(b, 1, 2, f);
}

void Put32(FILE *f, uint32_t v) {
    uint8_t b[4] = {static_cast<uint8_t>(v), static_cast<uint8_t>(v >> 8), static_cast<uint8_t>(v >> 16),
                    static_cast<uint8_t>(v >> 24)};
    fwrite(b, 1, 4, f);
}

void WriteWavHeader(FILE *f, int channels, uint32_t dataBytes) {
    fwrite("RIFF", 1, 4, f);
    Put32(f, 36 + dataBytes);
    fwrite("WAVEfmt ", 1, 8, f);
    Put32(f, 16);
    Put16(f, 1); // PCM
    Put16(f, static_cast<uint16_t>(channels));
    Put32(f, kOpusRate);
    Put32(f, kOpusRate * channels * 2);
    Put16(f, static_cast<uint16_t>(channels * 2));
    Put16(f, 16);
    fwrite("data", 1, 4, f);
    Put32(f, dataBytes);
}

// Generic async job: Execute() runs off the JS thread, Complete() builds the result.
struct Job {
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    std::string in;
    std::string out;
    std::string error;
    std::string result;
    double number = 0;
    void (*execute)(Job *) = nullptr;
};

void JobExecute(napi_env, void *data) {
    auto *job = static_cast<Job *>(data);
    job->execute(job);
}

void JobComplete(napi_env env, napi_status, void *data) {
    auto *job = static_cast<Job *>(data);
    if (job->error.empty()) {
        napi_value v;
        if (!job->result.empty()) {
            napi_create_string_utf8(env, job->result.data(), job->result.size(), &v);
        } else {
            napi_create_double(env, job->number, &v);
        }
        napi_resolve_deferred(env, job->deferred, v);
    } else {
        napi_value msg, err;
        napi_create_string_utf8(env, job->error.c_str(), NAPI_AUTO_LENGTH, &msg);
        napi_create_error(env, nullptr, msg, &err);
        napi_reject_deferred(env, job->deferred, err);
    }
    napi_delete_async_work(env, job->work);
    delete job;
}

napi_value StartJob(napi_env env, Job *job) {
    napi_value promise, name;
    napi_create_promise(env, &job->deferred, &promise);
    napi_create_string_utf8(env, "tdgramMedia", NAPI_AUTO_LENGTH, &name);
    napi_create_async_work(env, nullptr, name, JobExecute, JobComplete, job, &job->work);
    napi_queue_async_work(env, job->work);
    return promise;
}

void DecodeOpus(Job *job) {
    int err = 0;
    OggOpusFile *of = op_open_file(job->in.c_str(), &err);
    if (!of) {
        job->error = "cannot open opus file: " + std::to_string(err);
        return;
    }
    // Downmix to stereo-or-mono 16-bit PCM; voice notes are mono.
    int channels = std::min(op_channel_count(of, -1), 2);
    FILE *f = fopen(job->out.c_str(), "wb");
    if (!f) {
        op_free(of);
        job->error = "cannot write wav";
        return;
    }
    WriteWavHeader(f, channels, 0);
    std::vector<opus_int16> pcm(static_cast<size_t>(5760 * 2));
    uint64_t frames = 0;
    while (true) {
        int n = channels == 2 ? op_read_stereo(of, pcm.data(), static_cast<int>(pcm.size()))
                              : op_read(of, pcm.data(), static_cast<int>(pcm.size()), nullptr);
        if (n == OP_HOLE) continue;
        if (n <= 0) break;
        fwrite(pcm.data(), sizeof(opus_int16), static_cast<size_t>(n * channels), f);
        frames += static_cast<uint64_t>(n);
    }
    op_free(of);
    fseek(f, 0, SEEK_SET);
    WriteWavHeader(f, channels, static_cast<uint32_t>(frames * channels * 2));
    fclose(f);
    job->number = static_cast<double>(frames) / kOpusRate;
}

void Gunzip(Job *job) {
    gzFile gz = gzopen(job->in.c_str(), "rb");
    if (!gz) {
        job->error = "cannot open tgs";
        return;
    }
    char buf[16384];
    int n;
    while ((n = gzread(gz, buf, sizeof(buf))) > 0) {
        job->result.append(buf, static_cast<size_t>(n));
        if (job->result.size() > 16 * 1024 * 1024) { // Lottie stickers are far smaller
            job->error = "tgs too large";
            break;
        }
    }
    gzclose(gz);
    if (job->error.empty() && job->result.empty()) job->error = "empty tgs";
}

napi_value RunJob(napi_env env, napi_callback_info info, void (*fn)(Job *), size_t nargs) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    auto *job = new Job();
    job->execute = fn;
    job->in = GetString(env, args[0]);
    if (nargs > 1) job->out = GetString(env, args[1]);
    return StartJob(env, job);
}

napi_value DecodeOpusToWav(napi_env env, napi_callback_info info) { return RunJob(env, info, DecodeOpus, 2); }

napi_value GunzipToString(napi_env env, napi_callback_info info) { return RunJob(env, info, Gunzip, 1); }
// ---- Voice recording encoder ----
// Opus encoding of 16 kHz mono speech is cheap, so chunks are encoded
// synchronously on the JS thread as AudioCapturer delivers them.
std::mutex g_encMutex;
OggOpusEnc *g_enc = nullptr;
OggOpusComments *g_comments = nullptr;
int g_encRate = 0;
uint64_t g_encSamples = 0;
std::vector<int> g_peaks; // one peak per 10 ms block, for the waveform

// encoderStart(path, sampleRate): boolean
napi_value EncoderStart(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string path = GetString(env, args[0]);
    int32_t rate = 16000;
    napi_get_value_int32(env, args[1], &rate);
    std::lock_guard<std::mutex> lock(g_encMutex);
    if (g_enc) {
        ope_encoder_destroy(g_enc);
        g_enc = nullptr;
    }
    if (!g_comments) g_comments = ope_comments_create();
    int err = 0;
    g_enc = ope_encoder_create_file(path.c_str(), g_comments, rate, 1, 0, &err);
    bool ok = g_enc != nullptr;
    if (ok) {
        ope_encoder_ctl(g_enc, OPUS_SET_BITRATE(32000));
        ope_encoder_ctl(g_enc, OPUS_SET_SIGNAL(OPUS_SIGNAL_VOICE));
        g_encRate = rate;
        g_encSamples = 0;
        g_peaks.clear();
    }
    napi_value result;
    napi_get_boolean(env, ok, &result);
    return result;
}

// encoderWrite(pcm: ArrayBuffer) with 16-bit little-endian mono samples.
napi_value EncoderWrite(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value arg;
    napi_get_cb_info(env, info, &argc, &arg, nullptr, nullptr);
    void *data = nullptr;
    size_t len = 0;
    napi_get_arraybuffer_info(env, arg, &data, &len);
    std::lock_guard<std::mutex> lock(g_encMutex);
    if (!g_enc || !data) return nullptr;
    auto *pcm = static_cast<const opus_int16 *>(data);
    int samples = static_cast<int>(len / 2);
    ope_encoder_write(g_enc, pcm, samples);
    int block = std::max(g_encRate / 100, 1);
    for (int i = 0; i < samples; i += block) {
        int peak = 0;
        for (int j = i; j < std::min(i + block, samples); ++j) peak = std::max(peak, std::abs(int(pcm[j])));
        g_peaks.push_back(peak);
    }
    g_encSamples += static_cast<uint64_t>(samples);
    return nullptr;
}

// Telegram waveform: kWaveformBars 5-bit values, packed little-endian.
std::string PackWaveform(const std::vector<int> &peaks) {
    std::vector<int> bars(kWaveformBars, 0);
    if (!peaks.empty()) {
        int maxPeak = 1;
        for (size_t b = 0; b < bars.size(); ++b) {
            size_t from = b * peaks.size() / bars.size();
            size_t to = std::max(from + 1, (b + 1) * peaks.size() / bars.size());
            for (size_t i = from; i < to && i < peaks.size(); ++i) bars[b] = std::max(bars[b], peaks[i]);
            maxPeak = std::max(maxPeak, bars[b]);
        }
        for (int &v : bars) v = std::min(31, v * 31 / maxPeak);
    }
    std::string out((kWaveformBars * 5 + 7) / 8, '\0');
    for (int i = 0; i < kWaveformBars; ++i) {
        int bit = i * 5;
        int value = bars[static_cast<size_t>(i)] << (bit % 8);
        out[static_cast<size_t>(bit / 8)] |= static_cast<char>(value & 0xFF);
        if (bit / 8 + 1 < static_cast<int>(out.size())) {
            out[static_cast<size_t>(bit / 8 + 1)] |= static_cast<char>((value >> 8) & 0xFF);
        }
    }
    return out;
}

std::string Base64(const std::string &in) {
    static const char *chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    std::string out;
    size_t i = 0;
    for (; i + 2 < in.size(); i += 3) {
        uint32_t n = (uint8_t(in[i]) << 16) | (uint8_t(in[i + 1]) << 8) | uint8_t(in[i + 2]);
        out += chars[(n >> 18) & 63];
        out += chars[(n >> 12) & 63];
        out += chars[(n >> 6) & 63];
        out += chars[n & 63];
    }
    if (i < in.size()) {
        uint32_t n = uint8_t(in[i]) << 16;
        if (i + 1 < in.size()) n |= uint8_t(in[i + 1]) << 8;
        out += chars[(n >> 18) & 63];
        out += chars[(n >> 12) & 63];
        out += i + 1 < in.size() ? chars[(n >> 6) & 63] : '=';
        out += '=';
    }
    return out;
}

// encoderStop(): { duration: seconds, waveform: base64 } and finalizes the file.
napi_value EncoderStop(napi_env env, napi_callback_info) {
    std::lock_guard<std::mutex> lock(g_encMutex);
    double duration = 0;
    std::string waveform;
    if (g_enc) {
        ope_encoder_drain(g_enc);
        ope_encoder_destroy(g_enc);
        g_enc = nullptr;
        duration = g_encRate ? static_cast<double>(g_encSamples) / g_encRate : 0;
        waveform = Base64(PackWaveform(g_peaks));
    }
    napi_value result, d, w;
    napi_create_object(env, &result);
    napi_create_double(env, duration, &d);
    napi_create_string_utf8(env, waveform.data(), waveform.size(), &w);
    napi_set_named_property(env, result, "duration", d);
    napi_set_named_property(env, result, "waveform", w);
    return result;
}
} // namespace

void RegisterMedia(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"decodeOpusToWav", nullptr, DecodeOpusToWav, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"gunzipToString", nullptr, GunzipToString, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"encoderStart", nullptr, EncoderStart, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"encoderWrite", nullptr, EncoderWrite, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"encoderStop", nullptr, EncoderStop, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
}
