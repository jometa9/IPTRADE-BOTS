#include "Bridge/LocalEventPoster.h"
#include "Bridge/ApiAuth.h"
#include "Bridge/Encryption.h"

#include <windows.h>
#include <winhttp.h>

#include <chrono>
#include <sstream>
#include <algorithm>

#pragma comment(lib, "Winhttp.lib")

namespace bridge {

namespace {

std::wstring utf8_to_wstring(const std::string& input) {
    if (input.empty()) {
        return {};
    }
    int size_needed = MultiByteToWideChar(CP_UTF8, 0, input.c_str(), static_cast<int>(input.size()), nullptr, 0);
    std::wstring result(size_needed, 0);
    MultiByteToWideChar(CP_UTF8, 0, input.c_str(), static_cast<int>(input.size()), result.data(), size_needed);
    return result;
}

struct ParsedUrl {
    std::wstring host;
    std::wstring path;
    INTERNET_PORT port = INTERNET_DEFAULT_HTTP_PORT;
    DWORD flags = 0;
};

std::string trim(const std::string& str) {
    size_t first = str.find_first_not_of(" \t\n\r");
    if (first == std::string::npos) return "";
    size_t last = str.find_last_not_of(" \t\n\r");
    return str.substr(first, (last - first + 1));
}

bool parse_url(const std::string& url, ParsedUrl* out) {
    if (!out) return false;

    std::string trimmed_url = trim(url);
    if (trimmed_url.empty()) return false;
    std::wstring wide = utf8_to_wstring(trimmed_url);
    URL_COMPONENTS components;
    ZeroMemory(&components, sizeof(components));
    components.dwStructSize = sizeof(components);

    wchar_t host[256];
    wchar_t path[1024];
    components.lpszHostName = host;
    components.dwHostNameLength = _countof(host);
    components.lpszUrlPath = path;
    components.dwUrlPathLength = _countof(path);

    if (!WinHttpCrackUrl(wide.c_str(), 0, 0, &components)) {
        return false;
    }

    out->host.assign(components.lpszHostName, components.dwHostNameLength);
    out->path.assign(components.lpszUrlPath, components.dwUrlPathLength);
    out->port = components.nPort;
    out->flags = (components.nScheme == INTERNET_SCHEME_HTTPS) ? WINHTTP_FLAG_SECURE : 0;
    if (out->path.empty()) {
        out->path = L"/";
    }
    return true;
}

}

LocalEventPoster::LocalEventPoster() = default;
LocalEventPoster::~LocalEventPoster() {
    stop();
}

void LocalEventPoster::start(const std::string& external_url) {
    if (running_) {
        stop();
    }
    external_url_ = external_url;
    running_ = true;
}

void LocalEventPoster::stop() {
    running_ = false;

    auto start = std::chrono::steady_clock::now();
    while (active_threads_count_ > 0) {
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
        auto elapsed = std::chrono::steady_clock::now() - start;
        if (elapsed > std::chrono::seconds(5)) {
            break;
        }
    }
}

bool LocalEventPoster::enqueue(std::string json_payload) {
    if (!running_) {
        return false;
    }

    int current_count = active_threads_count_.load();

    send_async(std::move(json_payload));
    return true;
}

void LocalEventPoster::send_async(const std::string& payload) {

    active_threads_count_++;

    std::thread send_thread([this, payload]() {
        try {
            if (!send_payload(payload)) {

                std::this_thread::sleep_for(std::chrono::seconds(2));
                if (running_) {
                    send_async(payload);
                } else {
                    active_threads_count_--;
                }
            }
        } catch (...) {
        }

        active_threads_count_--;
    });

    send_thread.detach();
}

bool LocalEventPoster::send_payload(const std::string& payload) {
    if (external_url_.empty()) {
        return false;
    }

    ParsedUrl parsed;
    if (!parse_url(external_url_, &parsed)) {
        return false;
    }

    std::string final_payload = payload;
    if (Encryption::is_enabled()) {
        final_payload = Encryption::encrypt(payload);
    }

    HINTERNET hSession = WinHttpOpen(L"CopyBridge/1.0",
                                     WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
                                     WINHTTP_NO_PROXY_NAME,
                                     WINHTTP_NO_PROXY_BYPASS,
                                     0);
    if (!hSession) {
        return false;
    }

    HINTERNET hConnect = WinHttpConnect(hSession, parsed.host.c_str(), parsed.port, 0);
    if (!hConnect) {
        WinHttpCloseHandle(hSession);
        return false;
    }

    HINTERNET hRequest = WinHttpOpenRequest(hConnect,
                                            L"POST",
                                            parsed.path.c_str(),
                                            nullptr,
                                            WINHTTP_NO_REFERER,
                                            WINHTTP_DEFAULT_ACCEPT_TYPES,
                                            parsed.flags);
    if (!hRequest) {
        WinHttpCloseHandle(hConnect);
        WinHttpCloseHandle(hSession);
        return false;
    }

    std::string api_key = get_api_key_header_value();
    std::string api_secret = get_api_secret_header_value();
    std::wstring wapi_key = utf8_to_wstring(api_key);
    std::wstring wapi_secret = utf8_to_wstring(api_secret);
    std::wstring headers = L"Content-Type: application/json\r\n";
    headers += L"x-api-key: " + wapi_key + L"\r\n";
    headers += L"x-api-secret: " + wapi_secret + L"\r\n";
    WinHttpAddRequestHeaders(hRequest, headers.c_str(), static_cast<DWORD>(-1), WINHTTP_ADDREQ_FLAG_ADD);

    BOOL sent = WinHttpSendRequest(hRequest,
                                   WINHTTP_NO_ADDITIONAL_HEADERS,
                                   0,
                                   (LPVOID)final_payload.data(),
                                   static_cast<DWORD>(final_payload.size()),
                                   static_cast<DWORD>(final_payload.size()),
                                   0);

    if (!sent) {
        WinHttpCloseHandle(hRequest);
        WinHttpCloseHandle(hConnect);
        WinHttpCloseHandle(hSession);
        return false;
    }

    sent = WinHttpReceiveResponse(hRequest, nullptr);
    
    DWORD statusCode = 0;
    DWORD statusCodeSize = sizeof(statusCode);
    WinHttpQueryHeaders(hRequest,
                        WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                        WINHTTP_HEADER_NAME_BY_INDEX,
                        &statusCode,
                        &statusCodeSize,
                        WINHTTP_NO_HEADER_INDEX);

    WinHttpCloseHandle(hRequest);
    WinHttpCloseHandle(hConnect);
    WinHttpCloseHandle(hSession);
    
    return sent == TRUE && (statusCode >= 200 && statusCode < 300);
}

bool LocalEventPoster::send_now(const std::string& json_payload) {

    if (external_url_.empty()) {
        return false;
    }
    return send_payload(json_payload);
}

}

