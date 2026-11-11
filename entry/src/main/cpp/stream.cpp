// Loopback HTTP server that lets the system player read a file while TDLib
// is still downloading it, like the official apps' streaming playback.
//
// ArkTS opens a stream for a file and reports which byte ranges TDLib has
// written. When the player asks for bytes that are not there yet, the
// connection blocks and ArkTS is told to move the download offset there
// (e.g. to the moov atom at the end of an MP4, or to a seek position).
#include "stream.h"

#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <fcntl.h>
#include <map>
#include <mutex>
#include <netinet/in.h>
#include <string>
#include <sys/socket.h>
#include <thread>
#include <unistd.h>
#include <utility>
#include <vector>

namespace {
constexpr int64_t kChunk = 256 * 1024;
constexpr auto kWaitTimeout = std::chrono::seconds(60);

struct Stream {
    int64_t size = 0;
    std::string mime;
    std::string path;
    std::vector<std::pair<int64_t, int64_t>> ranges; // merged [start, end)
    int64_t lastNeed = -1;
    bool closed = false;
};

std::mutex g_mutex;
std::condition_variable g_cv;
std::map<int, Stream> g_streams;
int g_nextId = 1;
std::string g_base;  // http://127.0.0.1:<port>/<token>/
std::string g_token; // random path prefix so other apps can't read our files
napi_threadsafe_function g_onNeed = nullptr;

struct Need {
    int id;
    int64_t offset;
};

// End of the available run that contains pos, or pos when pos is missing.
int64_t CoveredEnd(const Stream &s, int64_t pos) {
    for (const auto &r : s.ranges) {
        if (r.first <= pos && pos < r.second) return r.second;
    }
    return pos;
}

void AddRange(Stream &s, int64_t start, int64_t end) {
    s.ranges.emplace_back(start, end);
    std::sort(s.ranges.begin(), s.ranges.end());
    std::vector<std::pair<int64_t, int64_t>> merged;
    for (const auto &r : s.ranges) {
        if (!merged.empty() && r.first <= merged.back().second) {
            merged.back().second = std::max(merged.back().second, r.second);
        } else {
            merged.push_back(r);
        }
    }
    s.ranges.swap(merged);
}

void CallNeedJs(napi_env env, napi_value cb, void *, void *data) {
    auto *need = static_cast<Need *>(data);
    if (env && cb) {
        napi_value args[2], undefined;
        napi_create_int32(env, need->id, &args[0]);
        napi_create_int64(env, need->offset, &args[1]);
        napi_get_undefined(env, &undefined);
        napi_call_function(env, undefined, cb, 2, args, nullptr);
    }
    delete need;
}

// Called with g_mutex held.
void RequestOffset(int id, Stream &s, int64_t pos) {
    // A sequential download already heading for pos needs no new offset.
    if (s.lastNeed >= 0 && pos >= s.lastNeed && pos <= CoveredEnd(s, s.lastNeed) + kChunk) return;
    s.lastNeed = pos;
    if (g_onNeed) napi_call_threadsafe_function(g_onNeed, new Need{id, pos}, napi_tsfn_nonblocking);
}

bool SendAll(int fd, const char *data, size_t len) {
    while (len > 0) {
        ssize_t n = send(fd, data, len, MSG_NOSIGNAL);
        if (n <= 0) return false;
        data += n;
        len -= static_cast<size_t>(n);
    }
    return true;
}

void Reply(int fd, const char *status) {
    std::string r = std::string("HTTP/1.1 ") + status + "\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
    SendAll(fd, r.data(), r.size());
}
void Serve(int fd) {
    std::string req;
    char buf[2048];
    while (req.find("\r\n\r\n") == std::string::npos && req.size() < 16384) {
        ssize_t n = recv(fd, buf, sizeof(buf), 0);
        if (n <= 0) return;
        req.append(buf, static_cast<size_t>(n));
    }
    // GET /<token>/<id> HTTP/1.1
    std::string prefix = "GET /" + g_token + "/";
    if (req.compare(0, prefix.size(), prefix) != 0) {
        Reply(fd, "404 Not Found");
        return;
    }
    int id = std::atoi(req.c_str() + prefix.size());
    int64_t start = 0, last = -1;
    bool ranged = false;
    size_t rp = req.find("\nRange: bytes=");
    if (rp == std::string::npos) rp = req.find("\nrange: bytes=");
    if (rp != std::string::npos) {
        ranged = true;
        long long a = 0, b = -1;
        if (std::sscanf(req.c_str() + rp + 14, "%lld-%lld", &a, &b) < 1) a = 0;
        start = a;
        last = b;
    }
    int64_t size;
    std::string mime;
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        auto it = g_streams.find(id);
        if (it == g_streams.end() || it->second.closed) {
            Reply(fd, "404 Not Found");
            return;
        }
        size = it->second.size;
        mime = it->second.mime;
    }
    if (last < 0 || last >= size) last = size - 1;
    if (start > last) {
        std::string r = "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */" + std::to_string(size) +
                        "\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
        SendAll(fd, r.data(), r.size());
        return;
    }
    std::string head = std::string("HTTP/1.1 ") + (ranged ? "206 Partial Content" : "200 OK") +
                       "\r\nContent-Type: " + mime + "\r\nAccept-Ranges: bytes\r\nContent-Length: " +
                       std::to_string(last - start + 1) + "\r\n";
    if (ranged) {
        head += "Content-Range: bytes " + std::to_string(start) + "-" + std::to_string(last) + "/" +
                std::to_string(size) + "\r\n";
    }
    head += "Connection: close\r\n\r\n";
    if (!SendAll(fd, head.data(), head.size())) return;

    std::vector<char> chunk(static_cast<size_t>(kChunk));
    int64_t pos = start;
    int file = -1;
    std::string openPath;
    while (pos <= last) {
        int64_t avail;
        std::string path;
        {
            std::unique_lock<std::mutex> lock(g_mutex);
            auto ready = [&]() {
                auto it = g_streams.find(id);
                return it == g_streams.end() || it->second.closed || CoveredEnd(it->second, pos) > pos;
            };
            if (!ready()) {
                RequestOffset(id, g_streams[id], pos);
                if (!g_cv.wait_for(lock, kWaitTimeout, ready)) break;
            }
            auto it = g_streams.find(id);
            if (it == g_streams.end() || it->second.closed) break;
            avail = std::min(CoveredEnd(it->second, pos), last + 1) - pos;
            path = it->second.path;
        }
        if (path != openPath) {
            if (file >= 0) close(file);
            file = open(path.c_str(), O_RDONLY);
            openPath = path;
            if (file < 0) break;
        }
        ssize_t n = pread(file, chunk.data(), static_cast<size_t>(std::min(avail, kChunk)), pos);
        if (n <= 0 || !SendAll(fd, chunk.data(), static_cast<size_t>(n))) break;
        pos += n;
    }
    if (file >= 0) close(file);
}

void AcceptLoop(int server) {
    while (true) {
        int fd = accept(server, nullptr, nullptr);
        if (fd < 0) continue;
        std::thread([fd]() {
            Serve(fd);
            close(fd);
        }).detach();
    }
}

bool StartServer() {
    int server = socket(AF_INET, SOCK_STREAM, 0);
    if (server < 0) return false;
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = 0;
    socklen_t len = sizeof(addr);
    if (bind(server, reinterpret_cast<sockaddr *>(&addr), sizeof(addr)) != 0 || listen(server, 16) != 0 ||
        getsockname(server, reinterpret_cast<sockaddr *>(&addr), &len) != 0) {
        close(server);
        return false;
    }
    unsigned char rnd[16] = {0};
    int ur = open("/dev/urandom", O_RDONLY);
    if (ur >= 0) {
        read(ur, rnd, sizeof(rnd));
        close(ur);
    }
    static const char *hex = "0123456789abcdef";
    for (unsigned char c : rnd) {
        g_token += hex[c >> 4];
        g_token += hex[c & 15];
    }
    g_base = "http://127.0.0.1:" + std::to_string(ntohs(addr.sin_port)) + "/" + g_token + "/";
    std::thread(AcceptLoop, server).detach();
    return true;
}

int64_t GetInt64(napi_env env, napi_value v) {
    int64_t r = 0;
    napi_get_value_int64(env, v, &r);
    return r;
}

std::string GetStr(napi_env env, napi_value v) {
    size_t len = 0;
    napi_get_value_string_utf8(env, v, nullptr, 0, &len);
    std::string s(len, '\0');
    napi_get_value_string_utf8(env, v, s.data(), len + 1, &len);
    return s;
}

// streamStart(onNeed: (streamId, offset) => void): boolean
napi_value StreamStart(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value cb;
    napi_get_cb_info(env, info, &argc, &cb, nullptr, nullptr);
    std::lock_guard<std::mutex> lock(g_mutex);
    bool ok = !g_base.empty() || StartServer();
    if (ok && !g_onNeed) {
        napi_value name;
        napi_create_string_utf8(env, "streamNeed", NAPI_AUTO_LENGTH, &name);
        napi_create_threadsafe_function(env, cb, nullptr, name, 64, 1, nullptr, nullptr, nullptr, CallNeedJs,
                                        &g_onNeed);
        // Don't keep the event loop alive for this.
        napi_unref_threadsafe_function(env, g_onNeed);
    }
    napi_value result;
    napi_get_boolean(env, ok, &result);
    return result;
}

// streamOpen(size, mime) -> { id, url }
napi_value StreamOpen(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int id;
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        id = g_nextId++;
        Stream &s = g_streams[id];
        s.size = GetInt64(env, args[0]);
        s.mime = GetStr(env, args[1]);
    }
    napi_value result, idVal, urlVal;
    napi_create_object(env, &result);
    napi_create_int32(env, id, &idVal);
    std::string url = g_base + std::to_string(id);
    napi_create_string_utf8(env, url.data(), url.size(), &urlVal);
    napi_set_named_property(env, result, "id", idVal);
    napi_set_named_property(env, result, "url", urlVal);
    return result;
}

// streamAvailable(id, path, offset, length): bytes [offset, offset+length) are on disk.
napi_value StreamAvailable(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t id = 0;
    napi_get_value_int32(env, args[0], &id);
    std::string path = GetStr(env, args[1]);
    int64_t offset = GetInt64(env, args[2]);
    int64_t length = GetInt64(env, args[3]);
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        auto it = g_streams.find(id);
        if (it == g_streams.end() || path.empty()) return nullptr;
        it->second.path = path;
        if (length > 0) AddRange(it->second, offset, std::min(offset + length, it->second.size));
    }
    g_cv.notify_all();
    return nullptr;
}

napi_value StreamClose(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value arg;
    napi_get_cb_info(env, info, &argc, &arg, nullptr, nullptr);
    int32_t id = 0;
    napi_get_value_int32(env, arg, &id);
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        g_streams.erase(id);
    }
    g_cv.notify_all();
    return nullptr;
}
} // namespace

void RegisterStream(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"streamStart", nullptr, StreamStart, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"streamOpen", nullptr, StreamOpen, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"streamAvailable", nullptr, StreamAvailable, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"streamClose", nullptr, StreamClose, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
}
