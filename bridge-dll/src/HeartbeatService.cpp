#include "Bridge/HeartbeatService.h"
#include "Bridge/ApiAuth.h"
#include <cstdio>
#include <sstream>
#include <vector>
#include <windows.h>
#include <winhttp.h>
#include <algorithm>
#include <thread>

#pragma comment(lib, "winhttp.lib")

namespace {
    const DWORD HEARTBEAT_HTTP_TIMEOUT_MS = 15000;
}

namespace bridge {

HeartbeatService& HeartbeatService::instance() {
    static HeartbeatService instance;
    return instance;
}

HeartbeatService::~HeartbeatService() {
    stop();
}

void HeartbeatService::set_current_account(const std::string& account_id, const std::string& account_json) {
    std::lock_guard<std::mutex> lock(data_mutex_);
    account_id_ = account_id;
    account_json_ = account_json;
}

void HeartbeatService::start(const std::string& account_id,
                            const std::string& account_json,
                            int local_port,
                            int tcp_port,
                            const std::string& heartbeat_url,
                            std::function<std::string()> get_master_tcp_url,
                            std::function<std::string()> get_copy_config_json) {
    std::lock_guard<std::mutex> lock(data_mutex_);
    
    if (running_.load()) {
        account_id_ = account_id;
        account_json_ = account_json;
        local_port_ = local_port;
        tcp_port_ = tcp_port;
        if (!heartbeat_url.empty()) {
            heartbeat_url_ = heartbeat_url;
        }
        if (get_master_tcp_url) {
            get_master_tcp_url_ = std::move(get_master_tcp_url);
        }
        if (get_copy_config_json) {
            get_copy_config_json_ = std::move(get_copy_config_json);
        }
        return;
    }
    
    account_id_ = account_id;
    account_json_ = account_json;
    local_port_ = local_port;
    tcp_port_ = tcp_port;
    heartbeat_url_ = heartbeat_url.empty() ? "http://localhost:3000/api/accounts/heartbeat" : heartbeat_url;
    get_master_tcp_url_ = std::move(get_master_tcp_url);
    get_copy_config_json_ = std::move(get_copy_config_json);
    has_snapshot_activity_ = true;
    last_snapshot_activity_ = std::chrono::steady_clock::now();
    
    running_ = true;
    heartbeat_thread_ = std::thread(&HeartbeatService::heartbeat_loop, this);
}

void HeartbeatService::stop() {
    if (!running_.load()) {
        return;
    }
    
    running_ = false;

    if (heartbeat_thread_.joinable()) {
        auto start = std::chrono::steady_clock::now();
        while (heartbeat_thread_.joinable()) {
            std::this_thread::sleep_for(std::chrono::milliseconds(50));
            auto elapsed = std::chrono::steady_clock::now() - start;
            if (elapsed > std::chrono::seconds(2)) {
                heartbeat_thread_.detach();
                break;
            }
        }
        if (heartbeat_thread_.joinable()) {
            heartbeat_thread_.join();
        }
    }
}

void HeartbeatService::update_account_info(const std::string& account_json, int local_port, int tcp_port) {
    std::lock_guard<std::mutex> lock(data_mutex_);
    account_json_ = account_json;
    local_port_ = local_port;
    tcp_port_ = tcp_port;
}

void HeartbeatService::update_tcp_port(int tcp_port) {
    std::lock_guard<std::mutex> lock(data_mutex_);
    tcp_port_ = tcp_port;
}

void HeartbeatService::mark_snapshot_activity() {
    std::lock_guard<std::mutex> lock(data_mutex_);
    has_snapshot_activity_ = true;
    last_snapshot_activity_ = std::chrono::steady_clock::now();
}

void HeartbeatService::set_terminal_connected(bool connected) {
    terminal_connected_.store(connected);
}

std::string HeartbeatService::get_account_id() const {
    std::lock_guard<std::mutex> lock(data_mutex_);
    return account_id_;
}

std::string HeartbeatService::get_account_json() const {
    std::lock_guard<std::mutex> lock(data_mutex_);
    return account_json_;
}

int HeartbeatService::get_local_port() const {
    std::lock_guard<std::mutex> lock(data_mutex_);
    return local_port_;
}

std::string HeartbeatService::get_account_server(const std::string& account_id) const {
    std::lock_guard<std::mutex> lock(data_mutex_);
    
    if (account_id != account_id_ || account_json_.empty()) {
        return "";
    }
    
    std::string server = "";
    size_t server_pos = account_json_.find("\"server\"");
    if (server_pos != std::string::npos) {
        size_t colon_pos = account_json_.find(':', server_pos);
        if (colon_pos != std::string::npos) {
            size_t start = account_json_.find('"', colon_pos);
            if (start != std::string::npos) {
                size_t end = account_json_.find('"', start + 1);
                if (end != std::string::npos) {
                    server = account_json_.substr(start + 1, end - start - 1);
                }
            }
        }
    }
    
    return server;
}

void HeartbeatService::heartbeat_loop() {
    try {
        if (should_send_heartbeat()) {
            send_heartbeat();
        }
    } catch (...) {
    }
    
    std::this_thread::sleep_for(std::chrono::seconds(HEARTBEAT_INTERVAL_SECONDS));
    
    while (running_.load()) {
        try {
            auto start_time = std::chrono::steady_clock::now();
            if (should_send_heartbeat()) {
                send_heartbeat();
            }
            
            auto elapsed = std::chrono::steady_clock::now() - start_time;
            auto remaining = std::chrono::seconds(HEARTBEAT_INTERVAL_SECONDS) - elapsed;
            
            if (remaining > std::chrono::seconds(0)) {
                std::this_thread::sleep_for(remaining);
            }
        } catch (...) {
            std::this_thread::sleep_for(std::chrono::seconds(HEARTBEAT_INTERVAL_SECONDS));
        }
    }
}

bool HeartbeatService::should_send_heartbeat() const {
    if (!terminal_connected_.load()) {
        return false;
    }
    std::lock_guard<std::mutex> lock(data_mutex_);
    return !account_id_.empty();
}

namespace {
    std::string extract_json_str(const std::string& json, const std::string& key) {
        std::string needle = "\"" + key + "\"";
        size_t key_pos = json.find(needle);
        if (key_pos == std::string::npos) return "";
        size_t colon_pos = json.find(':', key_pos + needle.size());
        if (colon_pos == std::string::npos) return "";
        size_t start = json.find('"', colon_pos);
        if (start == std::string::npos) return "";
        size_t end = json.find('"', start + 1);
        if (end == std::string::npos) return "";
        return json.substr(start + 1, end - start - 1);
    }
}

std::string HeartbeatService::build_form_data() {
    std::string account_id;
    std::string account_json;
    int local_port = 0;
    int tcp_port = 0;
    std::function<std::string()> get_master_tcp_url;
    std::function<std::string()> get_copy_config_json;
    {
        std::lock_guard<std::mutex> lock(data_mutex_);
        account_id = account_id_;
        account_json = account_json_;
        local_port = local_port_;
        tcp_port = tcp_port_;
        get_master_tcp_url = get_master_tcp_url_;
        get_copy_config_json = get_copy_config_json_;
    }

    std::string public_ip = "localhost";
    std::string api_url = "http://" + public_ip + ":" + std::to_string(local_port) + "/api/accounts/" + account_id;

    std::string platform = "metatrader5";
    size_t platform_pos = account_json.find("\"platform\"");
    if (platform_pos != std::string::npos) {
        size_t colon_pos = account_json.find(':', platform_pos);
        if (colon_pos != std::string::npos) {
            size_t start = account_json.find('"', colon_pos);
            if (start != std::string::npos) {
                size_t end = account_json.find('"', start + 1);
                if (end != std::string::npos) {
                    platform = account_json.substr(start + 1, end - start - 1);
                }
            }
        }
    }

    std::string server = "";
    size_t server_pos = account_json.find("\"server\"");
    if (server_pos != std::string::npos) {
        size_t colon_pos = account_json.find(':', server_pos);
        if (colon_pos != std::string::npos) {
            size_t start = account_json.find('"', colon_pos);
            if (start != std::string::npos) {
                size_t end = account_json.find('"', start + 1);
                if (end != std::string::npos) {
                    server = account_json.substr(start + 1, end - start - 1);
                }
            }
        }
    }

    std::string tcp_url_val;
    if (tcp_port > 0) {
        tcp_url_val = "tcp://" + public_ip + ":" + std::to_string(tcp_port);
    }

    auto json_escape = [](const std::string& s) -> std::string {
        std::string out;
        out.reserve(s.size() + 8);
        for (char c : s) {
            if (c == '"') out += "\\\"";
            else if (c == '\\') out += "\\\\";
            else if (c == '\n') out += "\\n";
            else if (c == '\r') out += "\\r";
            else if (c == '\t') out += "\\t";
            else out += c;
        }
        return out;
    };

    std::string platform_val = (platform == "metatrader4") ? "metatrader4" : "metatrader5";

    std::string role = "master";
    std::string master_tcp_url;
    if (get_copy_config_json) {
        std::string cfg = get_copy_config_json();
        if (!cfg.empty()) {
            std::string r = extract_json_str(cfg, "role");
            if (!r.empty()) role = r;
            master_tcp_url = extract_json_str(cfg, "master_tcp_url");
            if (master_tcp_url.empty()) master_tcp_url = extract_json_str(cfg, "masterTcpUrl");
        }
    }
    if (get_master_tcp_url) {
        std::string connected = get_master_tcp_url();
        if (!connected.empty()) master_tcp_url = connected;
    }
    std::ostringstream copy_cfg;
    copy_cfg << "{\"role\":\"" << json_escape(role) << "\",\"masterTcpUrl\":";
    copy_cfg << (master_tcp_url.empty() ? "null" : ("\"" + json_escape(master_tcp_url) + "\""));
    copy_cfg << "}";

    std::ostringstream json;
    json << "{";
    json << "\"api_url\":\"" << json_escape(api_url) << "\",";
    json << "\"platform\":\"" << json_escape(platform_val) << "\",";
    json << "\"connectionType\":\"ea\",";
    json << "\"account_id\":\"" << json_escape(account_id) << "\",";
    json << "\"server\":\"" << json_escape(server) << "\",";
    json << "\"success\":true,";
    if (tcp_url_val.empty()) {
        json << "\"tcp_url\":null,";
    } else {
        json << "\"tcp_url\":\"" << json_escape(tcp_url_val) << "\",";
    }
    json << "\"copyTradingConfig\":" << copy_cfg.str();
    json << "}";
    return json.str();
}

void HeartbeatService::send_heartbeat() {
    std::string url_to_use;
    {
        std::lock_guard<std::mutex> lock(data_mutex_);
        url_to_use = heartbeat_url_.empty() ? "http://localhost:3000/api/accounts/heartbeat" : heartbeat_url_;
    }

    std::wstring wurl(url_to_use.begin(), url_to_use.end());
    
    HINTERNET hSession = WinHttpOpen(L"BridgeHeartbeat/1.0",
                                    WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,
                                    WINHTTP_NO_PROXY_NAME,
                                    WINHTTP_NO_PROXY_BYPASS, 0);
    if (!hSession) return;
    
    URL_COMPONENTSW urlComp;
    ZeroMemory(&urlComp, sizeof(urlComp));
    urlComp.dwStructSize = sizeof(urlComp);
    urlComp.dwSchemeLength = (DWORD)-1;
    urlComp.dwHostNameLength = (DWORD)-1;
    urlComp.dwUrlPathLength = (DWORD)-1;
    
    if (!WinHttpCrackUrl(wurl.c_str(), (DWORD)wurl.length(), 0, &urlComp)) {
        WinHttpCloseHandle(hSession);
        return;
    }
    
    std::wstring host(urlComp.lpszHostName, urlComp.dwHostNameLength);
    std::wstring path(urlComp.lpszUrlPath, urlComp.dwUrlPathLength);
    
    HINTERNET hConnect = WinHttpConnect(hSession, host.c_str(),
                                       urlComp.nPort, 0);
    if (!hConnect) {
        WinHttpCloseHandle(hSession);
        return;
    }
    
    HINTERNET hRequest = WinHttpOpenRequest(hConnect, L"POST",
                                           path.c_str(),
                                           NULL, WINHTTP_NO_REFERER,
                                           WINHTTP_DEFAULT_ACCEPT_TYPES,
                                           (urlComp.nScheme == INTERNET_SCHEME_HTTPS) ? WINHTTP_FLAG_SECURE : 0);
    if (!hRequest) {
        WinHttpCloseHandle(hConnect);
        WinHttpCloseHandle(hSession);
        return;
    }
    
    std::string api_key = get_api_key_header_value();
    std::string api_secret = get_api_secret_header_value();
    std::wstring wapi_key(api_key.begin(), api_key.end());
    std::wstring wapi_secret(api_secret.begin(), api_secret.end());
    std::wstring headers = L"Content-Type: application/json\r\n";
    headers += L"x-api-key: " + wapi_key + L"\r\n";
    headers += L"x-api-secret: " + wapi_secret + L"\r\n";
    WinHttpAddRequestHeaders(hRequest, headers.c_str(), (DWORD)-1, WINHTTP_ADDREQ_FLAG_ADD);

    std::string json_body = build_form_data();

    if (WinHttpSendRequest(hRequest,
                          WINHTTP_NO_ADDITIONAL_HEADERS, 0,
                          (LPVOID)json_body.c_str(),
                          (DWORD)json_body.length(),
                          (DWORD)json_body.length(), 0)) {
        WinHttpReceiveResponse(hRequest, NULL);
    }
    WinHttpCloseHandle(hRequest);
    WinHttpCloseHandle(hConnect);
    WinHttpCloseHandle(hSession);
}

} 
