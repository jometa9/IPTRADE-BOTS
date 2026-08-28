#include "Bridge/BridgeServer.h"
#include "Bridge/ApiAuth.h"
#include "Bridge/Encryption.h"
#include "Bridge/ConfigApi.h"
#include "Bridge/AccountConfig.h"
#include "Bridge/HeartbeatService.h"
#include "Bridge/TcpServer.h"
#include "Bridge/TcpClient.h"
#include "Bridge/SlaveConverter.h"

#include <algorithm>
#include <chrono>
#include <cctype>
#include <cstdlib>
#include <cstring>
#include <sstream>
#include <thread>
#include <ctime>
#include <windows.h>
#include <stdio.h>
#include <winhttp.h>

#pragma comment(lib, "Winhttp.lib")

namespace bridge {

namespace {

/* Parse double locale-invariantly (MT4 may use comma as decimal separator) */
double parse_locale_invariant_double(const std::string& s) {
    std::string normalized = s;
    size_t comma = normalized.find(',');
    if (comma != std::string::npos) {
        normalized[comma] = '.';
    }
    return std::stod(normalized);
}

std::string json_escape(const std::string& input) {
    std::string output;
    output.reserve(input.size() + 2);
    for (char c : input) {
        switch (c) {
            case '"': output += "\\\""; break;
            case '\\': output += "\\\\"; break;
            case '\b': output += "\\b"; break;
            case '\f': output += "\\f"; break;
            case '\n': output += "\\n"; break;
            case '\r': output += "\\r"; break;
            case '\t': output += "\\t"; break;
            default:
                if (static_cast<unsigned char>(c) < 0x20) {
                    char buffer[7];
                    snprintf(buffer, sizeof(buffer), "\\u%04x", c);
                    output += buffer;
                } else {
                    output += c;
                }
        }
    }
    return output;
}

std::string current_iso_timestamp() {
    auto now = std::chrono::system_clock::now();
    auto time_t = std::chrono::system_clock::to_time_t(now);
    std::tm tm_buf;
    gmtime_s(&tm_buf, &time_t);
    char buffer[32];
    std::snprintf(buffer,
                  sizeof(buffer),
                  "%04d-%02d-%02dT%02d:%02d:%02dZ",
                  tm_buf.tm_year + 1900,
                  tm_buf.tm_mon + 1,
                  tm_buf.tm_mday,
                  tm_buf.tm_hour,
                  tm_buf.tm_min,
                  tm_buf.tm_sec);
    return std::string(buffer);
}

std::wstring utf8_to_wstring_bridge(const std::string& input) {
    if (input.empty()) {
        return {};
    }
    int size_needed = MultiByteToWideChar(CP_UTF8, 0, input.c_str(), static_cast<int>(input.size()), nullptr, 0);
    std::wstring result(size_needed, 0);
    MultiByteToWideChar(CP_UTF8, 0, input.c_str(), static_cast<int>(input.size()), result.data(), size_needed);
    return result;
}

struct ParsedUrlBridge {
    std::wstring host;
    std::wstring path;
    INTERNET_PORT port = INTERNET_DEFAULT_HTTP_PORT;
    DWORD flags = 0;
};

bool parse_url_bridge(const std::string& url, ParsedUrlBridge* out) {
    if (!out) return false;

    std::string trimmed_url = url;
    size_t first = trimmed_url.find_first_not_of(" \t\n\r");
    if (first == std::string::npos) return false;
    size_t last = trimmed_url.find_last_not_of(" \t\n\r");
    trimmed_url = trimmed_url.substr(first, (last - first + 1));

    if (trimmed_url.empty()) return false;
    std::wstring wide = utf8_to_wstring_bridge(trimmed_url);
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

constexpr const char kDefaultExternalUrl[] = "http://localhost:7777/api/heartbeat";
constexpr unsigned short kDefaultMinPort = 40000;
constexpr unsigned short kDefaultMaxPort = 50000;
constexpr const char kDefaultEncryptionKey[] = "CopyBridgeDefaultEncryptionKey32!!";
}

BridgeServer& BridgeServer::instance() {
    static BridgeServer server;
    return server;
}

BridgeServer::~BridgeServer() {
    stop();
}

std::string trim(const std::string& str) {
    size_t first = str.find_first_not_of(" \t\n\r");
    if (first == std::string::npos) return "";
    size_t last = str.find_last_not_of(" \t\n\r");
    return str.substr(first, (last - first + 1));
}

int BridgeServer::init(const std::string& external_url,
                       int min_port,
                       int max_port,
                       const std::string& encryption_key) {
    if (ready_) {
        return assigned_port();
    }

    external_url_ = trim(external_url);
    if (external_url_.empty()) {
        external_url_ = kDefaultExternalUrl;
    }

    std::string trimmed_key = trim(encryption_key);
    if (!trimmed_key.empty()) {
        Encryption::set_key(trimmed_key);
    } else {
        Encryption::set_key(kDefaultEncryptionKey);
    }

    unsigned short http_min = (min_port > 0 && max_port > 0)
        ? static_cast<unsigned short>(min_port)
        : kDefaultMinPort;
    unsigned short http_max = (min_port > 0 && max_port > 0)
        ? static_cast<unsigned short>(max_port)
        : kDefaultMaxPort;

    if (!server_.start(http_min, http_max)) {
        return -2;
    }

    assigned_port_ = server_.assigned_port();
    
    register_routes();

    tcp_min_port_ = static_cast<int>(http_min) + 10000;
    tcp_max_port_ = static_cast<int>(http_max) + 10000;
    if (!tcp_server_.start(tcp_min_port_, tcp_max_port_)) {
    } else {
        tcp_server_.set_on_new_session_callback([this](const std::string& account_id) {
            this->on_new_tcp_session(account_id);
        });
    }
    
    ready_ = true;

    if (!external_url_.empty()) {
        local_event_poster_.start(external_url_);
    } else {

    }

    std::vector<std::string> account_ids = ConfigApi::instance().get_all_account_ids();
    for (const auto& account_id : account_ids) {
        update_tcp_client(account_id);
    }

    maintenance_running_ = true;
    tcp_clients_maintenance_thread_ = std::thread(&BridgeServer::tcp_clients_maintenance_loop, this);

    return assigned_port();
}

void BridgeServer::stop() {
    if (!ready_) return;
    ready_ = false;
    HeartbeatService::instance().stop();
    tcp_server_.stop();
    
    maintenance_running_ = false;
    if (tcp_clients_maintenance_thread_.joinable()) {
        tcp_clients_maintenance_thread_.join();
    }
    
    {
        std::lock_guard<std::mutex> lock(tcp_clients_mutex_);
        tcp_clients_.clear(); 
    }
    server_.stop();
    local_event_poster_.stop();
    queue_.clear();
    {
        std::lock_guard<std::mutex> lock(pending_mutex_);
        pending_acks_.clear();
    }
}

int BridgeServer::poll_next_command(char* buffer, int buffer_len) {
    if (!buffer || buffer_len <= 0) {
        return -1;
    }

    std::string value;
    if (!queue_.try_pop(value)) {
        return 0;
    }

    int to_copy = static_cast<int>(std::min<size_t>(buffer_len - 1, value.size()));
    memcpy(buffer, value.data(), to_copy);
    buffer[to_copy] = '\0';
    return to_copy;
}

void BridgeServer::queue_command(const std::string& command_json) {
    queue_.push(command_json);
}

int BridgeServer::ack_command(long command_id,
                              int result_code,
                              const std::string& message,
                              const std::string& data_json) {
    std::shared_ptr<PendingAck> pending;
    {
        std::lock_guard<std::mutex> lock(pending_mutex_);
        auto it = pending_acks_.find(command_id);
        if (it == pending_acks_.end()) {
            return -1;
        }
        pending = it->second;
        pending_acks_.erase(it);
    }

    std::ostringstream data;
    data << "{";
    data << "\"command_id\":" << command_id << ",";
    data << "\"result_code\":" << result_code << ",";
    data << "\"message\":\"" << json_escape(message) << "\",";
    if (!data_json.empty()) {
        data << "\"data\":" << data_json;
    } else {
        data << "\"data\":null";
    }
    data << "}";

    pending->promise.set_value(data.str());
    return 1;
}

int BridgeServer::push_local_event(const std::string& json_event) {
    if (json_event.empty()) {
        return -1;
    }

    const bool is_snapshot_event = (extract_json_string_value(json_event, "event") == "snapshot");
    if (is_snapshot_event) {
        HeartbeatService::instance().mark_snapshot_activity();
    }

    std::string account_id = HeartbeatService::instance().get_account_id();
    if (account_id.empty()) {
        account_id = "0";
    }

    if (is_snapshot_event) {
        update_live_metrics_from_snapshot(account_id, json_event);
    }

    AccountConfig config;
    bool has_config = false;
    if (!account_id.empty()) {
        has_config = ConfigApi::instance().get_config(account_id, config);
    }
    
    bool tcp_running = tcp_server_.is_running();
    bool effective_on = tcp_connection_enabled_;
    if (!account_id.empty() && effective_on && tcp_running && has_config && config.is_master()) {
        AccountConfig config_now;
        if (!ConfigApi::instance().get_config(account_id, config_now) || !config_now.is_master()) {
            return 1;
        }
        std::string simplified_event = simplify_event_json(json_event);
        if (!simplified_event.empty()) {
            tcp_server_.broadcast_to_all(simplified_event);
            if (is_snapshot_event) {
                std::lock_guard<std::mutex> lock(last_snapshot_mutex_);
                last_snapshot_json_ = simplified_event;
            }
        }
    }
    return 1;
}

int BridgeServer::assigned_port() const {
    return assigned_port_;
}

int BridgeServer::send_ready_notification(const std::string& account_json, int local_port) {
    std::string account_id = extract_json_section(account_json, "login");
    if (account_id.empty()) {
        account_id = "0";
    }

    HeartbeatService::instance().set_current_account(account_id, account_json);

    std::string current = HeartbeatService::instance().get_account_id();
    std::vector<std::string> all_ids = ConfigApi::instance().get_all_account_ids();
    for (const auto& id : all_ids) {
        if (id != current) {
            ConfigApi::instance().delete_config(id);
            remove_tcp_client(id);
        }
    }
    std::string config_dir = ConfigApi::instance().get_config_directory();
    std::string search_path = config_dir + "\\config_*.json";
    WIN32_FIND_DATAA find_data;
    HANDLE find_handle = FindFirstFileA(search_path.c_str(), &find_data);
    if (find_handle != INVALID_HANDLE_VALUE) {
        do {
            if (!(find_data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)) {
                std::string filename = find_data.cFileName;
                if (filename.length() > 11 && filename.substr(0, 7) == "config_" && filename.substr(filename.length() - 5) == ".json") {
                    std::string file_account_id = filename.substr(7, filename.length() - 12);
                    if (file_account_id != current) {
                        std::string file_path = config_dir + "\\" + filename;
                        DeleteFileA(file_path.c_str());
                    }
                }
            }
        } while (FindNextFileA(find_handle, &find_data) != 0);
        FindClose(find_handle);
    }
    queue_.clear();

    ConfigApi::instance().allow_config_load(account_id);
    {
        AccountConfig dummy;
        if (!ConfigApi::instance().get_config(account_id, dummy))
            ConfigApi::instance().load_config_from_file(account_id);
    }

    update_tcp_client(account_id);

    AccountConfig config;
    bool has_config = ConfigApi::instance().get_config(account_id, config);
    int tcp_port = 0;
    if (has_config && config.is_master()) {
        tcp_port = tcp_server_.assigned_port();
    }
    std::string connected_master_tcp_url;
    if (has_config && config.is_slave() && !config.master_tcp_url.empty()) {
        connected_master_tcp_url = config.master_tcp_url;
    }

    HeartbeatService::instance().start(account_id, account_json, local_port, tcp_port, external_url_,
        [this, account_id]() { return get_connected_master_tcp_url(account_id); },
        [this, account_id]() {
            AccountConfig c;
            if (ConfigApi::instance().get_config(account_id, c)) return config_to_json(c);
            return std::string("");
        });

    if (!external_url_.empty()) {
        std::string server = extract_json_string_value(account_json, "server");
        std::string platform = extract_json_string_value(account_json, "platform");
        std::string platform_val = (platform == "metatrader4") ? "metatrader4" : "metatrader5";
        int actual_api_port = (local_port > 0) ? local_port : 3001;
        std::string api_url = "http://localhost:" + std::to_string(actual_api_port) + "/api/accounts/" + account_id;
        std::string tcp_url_val = (tcp_port > 0) ? "tcp://localhost:" + std::to_string(tcp_port) + "/" + account_id : "";

        std::ostringstream ready_json;
        ready_json << "{";
        ready_json << "\"api_url\":\"" << json_escape(api_url) << "\",";
        ready_json << "\"account_id\":\"" << json_escape(account_id) << "\",";
        ready_json << "\"platform\":\"" << json_escape(platform_val) << "\",";
        ready_json << "\"server\":\"" << json_escape(server) << "\",";
        if (tcp_url_val.empty()) {
            ready_json << "\"tcp_url\":null,";
        } else {
            ready_json << "\"tcp_url\":\"" << json_escape(tcp_url_val) << "\",";
        }
        if (!connected_master_tcp_url.empty()) {
            ready_json << "\"master_tcp_url\":\"" << json_escape(connected_master_tcp_url) << "\",";
        }
        ready_json << "\"copyTradingConfig\":";
        if (has_config) {
            ready_json << config_to_json(config);
        } else {
            ready_json << "null";
        }
        ready_json << ",";
        ready_json << "\"apiKey\":\"" << json_escape(get_api_key_header_value()) << "\",";
        ready_json << "\"apiSecret\":\"" << json_escape(get_api_secret_header_value()) << "\"";
        ready_json << "}";

        std::string ready_payload = ready_json.str();

        if (!local_event_poster_.is_running()) {
            local_event_poster_.start(external_url_);
        }

        std::string response;
        if (http_post_sync(external_url_, ready_payload, response)) {
            return 1;
        }
    }
    
    return 1; 
}

void BridgeServer::send_ready_event_immediate() {
    if (external_url_.empty()) return;
    std::string account_id = HeartbeatService::instance().get_account_id();
    if (account_id.empty()) return;

    AccountConfig config;
    bool has_config = ConfigApi::instance().get_config(account_id, config);
    int tcp_port = 0;
    if (has_config && config.is_master()) {
        tcp_port = tcp_server_.assigned_port();
    }
    std::string connected_master_tcp_url;
    if (has_config && config.is_slave() && !config.master_tcp_url.empty()) {
        connected_master_tcp_url = config.master_tcp_url;
    }

    std::string account_json = HeartbeatService::instance().get_account_json();
    std::string server = extract_json_string_value(account_json, "server");
    std::string platform = extract_json_string_value(account_json, "platform");
    std::string platform_val = (platform == "metatrader4") ? "metatrader4" : "metatrader5";
    int actual_api_port = HeartbeatService::instance().get_local_port();
    if (actual_api_port <= 0) actual_api_port = assigned_port();
    if (actual_api_port <= 0) actual_api_port = 3001;
    std::string api_url = "http://localhost:" + std::to_string(actual_api_port) + "/api/accounts/" + account_id;
    std::string tcp_url_val = (tcp_port > 0) ? "tcp://localhost:" + std::to_string(tcp_port) + "/" + account_id : "";

    std::ostringstream ready_json;
    ready_json << "{";
    ready_json << "\"api_url\":\"" << json_escape(api_url) << "\",";
    ready_json << "\"account_id\":\"" << json_escape(account_id) << "\",";
    ready_json << "\"platform\":\"" << json_escape(platform_val) << "\",";
    ready_json << "\"server\":\"" << json_escape(server) << "\",";
    if (tcp_url_val.empty()) {
        ready_json << "\"tcp_url\":null,";
    } else {
        ready_json << "\"tcp_url\":\"" << json_escape(tcp_url_val) << "\",";
    }
    if (!connected_master_tcp_url.empty()) {
        ready_json << "\"master_tcp_url\":\"" << json_escape(connected_master_tcp_url) << "\",";
    }
    ready_json << "\"copyTradingConfig\":";
    if (has_config) {
        ready_json << config_to_json(config);
    } else {
        ready_json << "null";
    }
    ready_json << ",";
    ready_json << "\"apiKey\":\"" << json_escape(get_api_key_header_value()) << "\",";
    ready_json << "\"apiSecret\":\"" << json_escape(get_api_secret_header_value()) << "\"";
    ready_json << "}";

    std::string ready_payload = ready_json.str();
    if (!local_event_poster_.is_running()) {
        local_event_poster_.start(external_url_);
    }
    std::string response;
    http_post_sync(external_url_, ready_payload, response);
}

void BridgeServer::broadcast_last_snapshot_to_tcp_if_effective() {
    std::string account_id = HeartbeatService::instance().get_account_id();
    if (account_id.empty()) return;
    AccountConfig config;
    bool has_config = ConfigApi::instance().get_config(account_id, config);
    bool effective_on = tcp_connection_enabled_;
    if (!tcp_server_.is_running() || !effective_on || !has_config || !config.is_master())
        return;
    std::string snapshot;
    {
        std::lock_guard<std::mutex> lock(last_snapshot_mutex_);
        snapshot = last_snapshot_json_;
    }
    if (!snapshot.empty())
        tcp_server_.broadcast_to_all(snapshot);
}

void BridgeServer::on_new_tcp_session(const std::string&) {
    broadcast_last_snapshot_to_tcp_if_effective();
}

static std::optional<HttpResponse> check_api_auth(const HttpRequest& req) {
    std::string key = req.headers.count("x-api-key") ? req.headers.at("x-api-key") : "";
    std::string secret = req.headers.count("x-api-secret") ? req.headers.at("x-api-secret") : "";
    if ((key.empty() || secret.empty()) && (req.method == "POST" || req.method == "PUT") && !req.body.empty()) {
        auto extract = [](const std::string& body, const char* name) -> std::string {
            std::string needle = std::string("\"") + name + "\":\"";
            size_t pos = body.find(needle);
            if (pos == std::string::npos) return "";
            pos += needle.size();
            size_t end = pos;
            while (end < body.size() && body[end] != '"' && body[end] != '\\') ++end;
            return body.substr(pos, end - pos);
        };
        if (key.empty()) key = extract(req.body, "apiKey");
        if (secret.empty()) secret = extract(req.body, "apiSecret");
    }
    key.erase(std::remove(key.begin(), key.end(), '\0'), key.end());
    secret.erase(std::remove(secret.begin(), secret.end(), '\0'), secret.end());
    std::string expected_key = get_api_key_header_value();
    std::string expected_secret = get_api_secret_header_value();
    if (key != expected_key || secret != expected_secret) {
        HttpResponse r;
        r.status = 401;
        r.body = R"({"success":false,"error":{"code":"unauthorized","message":"Invalid or missing x-api-key / x-api-secret"},"data":null})";
        return r;
    }
    return std::nullopt;
}

void BridgeServer::register_routes() {
    server_.register_handler("PUT", "/api/accounts", [this](const HttpRequest& req) {
        if (auto unauth = check_api_auth(req)) return *unauth;
        std::string path_lower = req.path;
        std::transform(path_lower.begin(), path_lower.end(), path_lower.begin(), ::tolower);
        size_t q = path_lower.find('?');
        std::string path_only = (q != std::string::npos) ? path_lower.substr(0, q) : path_lower;
        if (path_only.size() >= 4 && path_only.compare(path_only.size() - 4, 4, "/tcp") == 0) {
            return handle_put_tcp(req);
        }
        return handle_put_config(req);
    });
    server_.register_handler("POST", "/api/accounts", [this](const HttpRequest& req) {
        if (auto unauth = check_api_auth(req)) return *unauth;
        return handle_post_config(req);
    });
    server_.register_stream_handler("GET", "/api/accounts", [this](const HttpRequest& req, SOCKET client_socket) {
        std::string path_lower = req.path;
        std::transform(path_lower.begin(), path_lower.end(), path_lower.begin(), ::tolower);
        if (path_lower.find("/orders") != std::string::npos) {
            return handle_ws_metrics_stream(req, client_socket);
        }
        return false;
    });
}

bool BridgeServer::has_valid_api_auth(const HttpRequest& req) {
    std::string key = req.headers.count("x-api-key") ? req.headers.at("x-api-key") : "";
    std::string secret = req.headers.count("x-api-secret") ? req.headers.at("x-api-secret") : "";
    if ((key.empty() || secret.empty()) &&
        (req.method == "POST" || req.method == "PUT" || req.method == "DELETE") &&
        !req.body.empty()) {
        auto extract = [](const std::string& body, const char* name) -> std::string {
            std::string needle = std::string("\"") + name + "\":\"";
            size_t pos = body.find(needle);
            if (pos == std::string::npos) return "";
            pos += needle.size();
            size_t end = pos;
            while (end < body.size() && body[end] != '"' && body[end] != '\\') ++end;
            return body.substr(pos, end - pos);
        };
        if (key.empty()) key = extract(req.body, "apiKey");
        if (secret.empty()) secret = extract(req.body, "apiSecret");
    }
    key.erase(std::remove(key.begin(), key.end(), '\0'), key.end());
    secret.erase(std::remove(secret.begin(), secret.end(), '\0'), secret.end());
    return key == get_api_key_header_value() && secret == get_api_secret_header_value();
}

bool BridgeServer::parse_json_bool(const std::string& source, const std::string& key, bool* value_out, bool* key_present_out) {
    std::string raw = extract_json_section(source, key);
    if (key_present_out) *key_present_out = !raw.empty();
    if (raw.empty()) return false;
    if (raw == "true") {
        if (value_out) *value_out = true;
        return true;
    }
    if (raw == "false") {
        if (value_out) *value_out = false;
        return true;
    }
    return false;
}

bool BridgeServer::parse_json_long(const std::string& source, const std::string& key, long* value_out, bool* key_present_out) {
    std::string raw = extract_json_section(source, key);
    if (key_present_out) *key_present_out = !raw.empty();
    if (raw.empty() || raw == "null") return false;
    char* end_ptr = nullptr;
    long value = std::strtol(raw.c_str(), &end_ptr, 10);
    if (end_ptr == raw.c_str()) return false;
    while (end_ptr && *end_ptr != '\0' && std::isspace(static_cast<unsigned char>(*end_ptr))) ++end_ptr;
    if (end_ptr && *end_ptr != '\0') return false;
    if (value_out) *value_out = value;
    return true;
}

bool BridgeServer::parse_json_double(const std::string& source, const std::string& key, double* value_out, bool* key_present_out) {
    std::string raw = extract_json_section(source, key);
    if (key_present_out) *key_present_out = !raw.empty();
    if (raw.empty() || raw == "null") return false;
    char* end_ptr = nullptr;
    double value = std::strtod(raw.c_str(), &end_ptr);
    if (end_ptr == raw.c_str()) return false;
    while (end_ptr && *end_ptr != '\0' && std::isspace(static_cast<unsigned char>(*end_ptr))) ++end_ptr;
    if (end_ptr && *end_ptr != '\0') return false;
    if (value_out) *value_out = value;
    return true;
}

bool BridgeServer::parse_json_nullable_double(const std::string& source,
                                              const std::string& key,
                                              double* value_out,
                                              bool* key_present_out,
                                              bool* is_null_out) {
    std::string raw = extract_json_section(source, key);
    if (key_present_out) *key_present_out = !raw.empty();
    if (raw.empty()) return false;
    if (raw == "null") {
        if (is_null_out) *is_null_out = true;
        if (value_out) *value_out = 0.0;
        return true;
    }
    if (is_null_out) *is_null_out = false;
    return parse_json_double(source, key, value_out, nullptr);
}

bool BridgeServer::parse_json_nullable_string(const std::string& source,
                                              const std::string& key,
                                              std::string* value_out,
                                              bool* key_present_out,
                                              bool* is_null_out) {
    std::string raw = extract_json_section(source, key);
    if (key_present_out) *key_present_out = !raw.empty();
    if (raw.empty()) return false;
    if (raw == "null") {
        if (is_null_out) *is_null_out = true;
        if (value_out) value_out->clear();
        return true;
    }
    if (raw.size() < 2 || raw.front() != '"' || raw.back() != '"') {
        return false;
    }
    if (is_null_out) *is_null_out = false;
    if (value_out) *value_out = extract_json_string_value(source, key);
    return true;
}

std::string BridgeServer::wrap_response(bool success,
                                        const std::string& data,
                                        const std::string& error_message) const {
    std::ostringstream ss;
    ss << "{";
    ss << "\"success\":" << (success ? "true" : "false") << ",";
    if (success) {
        ss << "\"error\":null";
    } else {
        (void)error_message;
        ss << "\"error\":\"Error\"";
    }
    ss << "}";
    return ss.str();
}

std::string BridgeServer::extract_json_section(const std::string& source, const std::string& key) {
    std::string needle = "\"" + key + "\"";
    size_t key_pos = source.find(needle);
    if (key_pos == std::string::npos) {
        return "";
    }

    size_t colon_pos = source.find(':', key_pos + needle.size());
    if (colon_pos == std::string::npos) {
        return "";
    }

    size_t value_pos = colon_pos + 1;
    while (value_pos < source.size() &&
           std::isspace(static_cast<unsigned char>(source[value_pos]))) {
        ++value_pos;
    }
    if (value_pos >= source.size()) {
        return "";
    }

    char start_char = source[value_pos];
    if (start_char == '{' || start_char == '[') {
        char open_char = start_char;
        char close_char = (start_char == '{') ? '}' : ']';
        int depth = 0;
        bool in_string = false;
        bool escape = false;
        for (size_t i = value_pos; i < source.size(); ++i) {
            char ch = source[i];
            if (in_string) {
                if (escape) {
                    escape = false;
                } else if (ch == '\\') {
                    escape = true;
                } else if (ch == '"') {
                    in_string = false;
                }
                continue;
            }
            if (ch == '"') {
                in_string = true;
                continue;
            }
            if (ch == open_char) {
                depth++;
            } else if (ch == close_char) {
                depth--;
                if (depth == 0) {
                    return source.substr(value_pos, i - value_pos + 1);
                }
            }
        }
        return "";
    }

    size_t end_pos = value_pos;
    while (end_pos < source.size() &&
           source[end_pos] != ',' &&
           source[end_pos] != '}' &&
           source[end_pos] != '\n' &&
           source[end_pos] != '\r') {
        ++end_pos;
    }
    return source.substr(value_pos, end_pos - value_pos);
}

std::string BridgeServer::extract_json_string_value(const std::string& source, const std::string& key) {
    std::string needle = "\"" + key + "\"";
    size_t key_pos = source.find(needle);
    if (key_pos == std::string::npos) {
        return "";
    }

    size_t colon_pos = source.find(':', key_pos + needle.size());
    if (colon_pos == std::string::npos) {
        return "";
    }

    size_t value_pos = colon_pos + 1;
    while (value_pos < source.size() &&
           std::isspace(static_cast<unsigned char>(source[value_pos]))) {
        ++value_pos;
    }
    if (value_pos >= source.size()) {
        return "";
    }

    if (source[value_pos] == '"') {
        size_t start = value_pos + 1;
        size_t end = start;
        bool escape = false;
        while (end < source.size()) {
            char ch = source[end];
            if (escape) {
                escape = false;
                end++;
                continue;
            }
            if (ch == '\\') {
                escape = true;
                end++;
                continue;
            }
            if (ch == '"') {
                return source.substr(start, end - start);
            }
            end++;
        }
    } else if (std::isdigit(static_cast<unsigned char>(source[value_pos])) || source[value_pos] == '-') {
        size_t start = value_pos;
        size_t end = start + 1;
        while (end < source.size() && 
               (std::isdigit(static_cast<unsigned char>(source[end])) || 
                source[end] == '.' || source[end] == 'e' || source[end] == 'E' || 
                source[end] == '+' || source[end] == '-')) {
            end++;
        }
        while (end < source.size() && 
               source[end] != ',' && source[end] != '}' && source[end] != ']' &&
               !std::isspace(static_cast<unsigned char>(source[end]))) {
            end++;
        }
        return source.substr(start, end - start);
    }
    return "";
}

std::string BridgeServer::extract_json_numeric_or_null(const std::string& source, const std::string& key) {
    std::string needle = "\"" + key + "\"";
    size_t key_pos = source.find(needle);
    if (key_pos == std::string::npos) {
        return "";
    }

    size_t colon_pos = source.find(':', key_pos + needle.size());
    if (colon_pos == std::string::npos) {
        return "";
    }

    size_t value_pos = colon_pos + 1;
    while (value_pos < source.size() &&
           std::isspace(static_cast<unsigned char>(source[value_pos]))) {
        ++value_pos;
    }
    if (value_pos >= source.size()) {
        return "";
    }

    if (source.substr(value_pos, 4) == "null") {
        return "null";
    }

    if (std::isdigit(static_cast<unsigned char>(source[value_pos])) || source[value_pos] == '-') {
        size_t start = value_pos;
        size_t end = start + 1;
        while (end < source.size() && 
               (std::isdigit(static_cast<unsigned char>(source[end])) || 
                source[end] == '.' || source[end] == 'e' || source[end] == 'E' || 
                source[end] == '+' || source[end] == '-')) {
            end++;
        }
        while (end < source.size() && 
               source[end] != ',' && source[end] != '}' && source[end] != ']' &&
               !std::isspace(static_cast<unsigned char>(source[end]))) {
            end++;
        }
        return source.substr(start, end - start);
    }
    return "";
}

std::string BridgeServer::simplify_event_json(const std::string& json_event) {
    if (json_event.empty()) {
        return "";
    }

    std::string event_type = extract_json_string_value(json_event, "event");
    if (event_type.empty()) {
        return json_event;
    }

    std::ostringstream simplified;
    simplified << "{";

    bool first_field = true;

    if (event_type == "placed") {
        simplified << "\"event\":\"" << json_escape(event_type) << "\"";
        first_field = false;
        
        std::string ticket = extract_json_numeric_or_null(json_event, "ticket");
        if (!ticket.empty()) {
            simplified << ",\"ticket\":" << ticket;
        }
        
        std::string symbol = extract_json_string_value(json_event, "symbol");
        if (!symbol.empty()) {
            simplified << ",\"symbol\":\"" << json_escape(symbol) << "\"";
        }
        
        std::string type = extract_json_string_value(json_event, "type");
        if (!type.empty()) {
            simplified << ",\"type\":\"" << json_escape(type) << "\"";
        }
        
        std::string side = extract_json_string_value(json_event, "side");
        if (!side.empty()) {
            simplified << ",\"side\":\"" << json_escape(side) << "\"";
        }
        
        std::string volume = extract_json_numeric_or_null(json_event, "volume");
        if (!volume.empty()) {
            simplified << ",\"volume\":" << volume;
        }
        
        std::string price = extract_json_numeric_or_null(json_event, "price");
        if (!price.empty()) {
            simplified << ",\"price\":" << price;
        }
        
        std::string sl = extract_json_numeric_or_null(json_event, "sl");
        if (!sl.empty()) {
            simplified << ",\"sl\":" << sl;
        }
        
        std::string tp = extract_json_numeric_or_null(json_event, "tp");
        if (!tp.empty()) {
            simplified << ",\"tp\":" << tp;
        }

        std::string age_seconds = extract_json_numeric_or_null(json_event, "age_seconds");
        if (!age_seconds.empty()) {
            simplified << ",\"age_seconds\":" << age_seconds;
        }

    } else if (event_type == "modified") {
        simplified << "\"event\":\"" << json_escape(event_type) << "\"";
        first_field = false;

        std::string ticket = extract_json_numeric_or_null(json_event, "ticket");
        if (!ticket.empty()) {
            simplified << ",\"ticket\":" << ticket;
        }

        std::string sl = extract_json_numeric_or_null(json_event, "sl");
        if (!sl.empty()) {
            simplified << ",\"sl\":" << sl;
        }

        std::string tp = extract_json_numeric_or_null(json_event, "tp");
        if (!tp.empty()) {
            simplified << ",\"tp\":" << tp;
        }

        std::string price = extract_json_numeric_or_null(json_event, "price");
        if (!price.empty()) {
            simplified << ",\"price\":" << price;
        }

        std::string volume = extract_json_numeric_or_null(json_event, "volume");
        if (!volume.empty()) {
            simplified << ",\"volume\":" << volume;
        }

        std::string age_seconds = extract_json_numeric_or_null(json_event, "age_seconds");
        if (!age_seconds.empty()) {
            simplified << ",\"age_seconds\":" << age_seconds;
        }

    } else if (event_type == "closed") {
        simplified << "\"event\":\"" << json_escape(event_type) << "\"";
        
        std::string ticket = extract_json_numeric_or_null(json_event, "ticket");
        if (!ticket.empty()) {
            simplified << ",\"ticket\":" << ticket;
        }
    } else if (event_type == "snapshot") {
        simplified << "\"event\":\"" << json_escape(event_type) << "\"";
        std::string open_positions = extract_json_section(json_event, "open_positions");
        if (!open_positions.empty()) {
            simplified << ",\"open_positions\":" << open_positions;
        } else {
            simplified << ",\"open_positions\":[]";
        }
        std::string pending_orders = extract_json_section(json_event, "pending_orders");
        if (!pending_orders.empty()) {
            simplified << ",\"pending_orders\":" << pending_orders;
        } else {
            simplified << ",\"pending_orders\":[]";
        }
    } else {
        return json_event;
    }

    simplified << "}";
    return simplified.str();
}

bool BridgeServer::http_post_sync(const std::string& url, const std::string& body,
                                   std::string& response_out) {
    ParsedUrlBridge parsed;
    if (!parse_url_bridge(url, &parsed)) {
        return false;
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
    std::wstring wapi_key = utf8_to_wstring_bridge(api_key);
    std::wstring wapi_secret = utf8_to_wstring_bridge(api_secret);
    std::wstring headers = L"Content-Type: application/json\r\n";
    headers += L"x-api-key: " + wapi_key + L"\r\n";
    headers += L"x-api-secret: " + wapi_secret + L"\r\n";
    if (!WinHttpAddRequestHeaders(hRequest, headers.c_str(), static_cast<DWORD>(-1), WINHTTP_ADDREQ_FLAG_ADD)) {
        WinHttpCloseHandle(hRequest);
        WinHttpCloseHandle(hConnect);
        WinHttpCloseHandle(hSession);
        return false;
    }

    BOOL sent = WinHttpSendRequest(hRequest,
                                   WINHTTP_NO_ADDITIONAL_HEADERS,
                                   0,
                                   (LPVOID)body.data(),
                                   static_cast<DWORD>(body.size()),
                                   static_cast<DWORD>(body.size()),
                                   0);

    if (!sent) {
        WinHttpCloseHandle(hRequest);
        WinHttpCloseHandle(hConnect);
        WinHttpCloseHandle(hSession);
        return false;
    }

    if (!WinHttpReceiveResponse(hRequest, nullptr)) {
        WinHttpCloseHandle(hRequest);
        WinHttpCloseHandle(hConnect);
        WinHttpCloseHandle(hSession);
        return false;
    }

    DWORD statusCode = 0;
    DWORD statusCodeSize = sizeof(statusCode);
    WinHttpQueryHeaders(hRequest,
                        WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                        WINHTTP_HEADER_NAME_BY_INDEX,
                        &statusCode,
                        &statusCodeSize,
                        WINHTTP_NO_HEADER_INDEX);

    response_out.clear();
    DWORD dwSize = 0;
    DWORD dwDownloaded = 0;
    do {
        dwSize = 0;
        if (!WinHttpQueryDataAvailable(hRequest, &dwSize)) {
            break;
        }
        if (dwSize == 0) break;

        std::vector<char> buffer(dwSize + 1);
        if (!WinHttpReadData(hRequest, buffer.data(), dwSize, &dwDownloaded)) {
            break;
        }
        response_out.append(buffer.data(), dwDownloaded);
    } while (dwSize > 0);

    WinHttpCloseHandle(hRequest);
    WinHttpCloseHandle(hConnect);
    WinHttpCloseHandle(hSession);
    
    return (statusCode >= 200 && statusCode < 300);
}

std::string BridgeServer::extract_account_id_from_path(const std::string& path) {
    std::string normalized = path;
    std::transform(normalized.begin(), normalized.end(), normalized.begin(), ::tolower);

    size_t route_pos = normalized.find("/api/accounts/");
    size_t prefix_len = 14;
    if (route_pos == std::string::npos) {
        route_pos = normalized.find("/api/trade/");
        prefix_len = 11;
    }
    if (route_pos != std::string::npos) {
        size_t start = route_pos + prefix_len;
        size_t end = path.find_first_of("?/", start);
        if (end == std::string::npos) {
            end = path.size();
        }
        if (start < path.size() && end > start) {
            return path.substr(start, end - start);
        }
    }
    
    size_t query_pos = path.find('?');
    if (query_pos != std::string::npos) {
        std::string query = path.substr(query_pos + 1);
        size_t account_pos = query.find("account_id=");
        if (account_pos != std::string::npos) {
            size_t start = account_pos + 11;
            size_t end = query.find('&', start);
            if (end == std::string::npos) {
                end = query.size();
            }
            if (start < query.size() && end > start) {
                return query.substr(start, end - start);
            }
        }
    }
    
    return "";
}

static bool json_object_has_key(const std::string& json, const std::string& key) {
    std::string needle = "\"" + key + "\":";
    return json.find(needle) != std::string::npos;
}

static bool json_object_has_any_key(const std::string& json, const std::string& key_snake, const std::string& key_camel) {
    return json_object_has_key(json, key_snake) || json_object_has_key(json, key_camel);
}

AccountConfig BridgeServer::parse_config_json_merge(const std::string& json, const AccountConfig& base) {
    AccountConfig config = base;
    if (json_object_has_key(json, "role")) {
        config.role = extract_json_string_value(json, "role");
    }
    if (json_object_has_any_key(json, "master_tcp_url", "masterTcpUrl")) {
        config.master_tcp_url = extract_json_string_value(json, "master_tcp_url");
        if (config.master_tcp_url.empty()) {
            config.master_tcp_url = extract_json_string_value(json, "masterTcpUrl");
        }
    }
    if (json_object_has_any_key(json, "lot_type", "lotType")) {
        config.lot_type = extract_json_string_value(json, "lot_type");
        if (config.lot_type.empty()) {
            config.lot_type = extract_json_string_value(json, "lotType");
        }
        if (config.lot_type.empty()) {
            config.lot_type = "multiplier";
        }
        if (config.lot_type == "fixedlot") {
            config.lot_type = "fixed";
        }
    }
    if (json_object_has_any_key(json, "lot_multiplier", "lotMultiplier")) {
        std::string lot_mult_str = extract_json_section(json, "lot_multiplier");
        if (lot_mult_str.empty()) {
            lot_mult_str = extract_json_section(json, "lotMultiplier");
        }
        if (!lot_mult_str.empty()) {
            try {
                config.lot_multiplier = std::stod(lot_mult_str);
            } catch (...) {
                config.lot_multiplier = 1.0;
            }
        }
    }
    if (json_object_has_any_key(json, "fixed_lot", "fixedLot")) {
        std::string fixed_lot_str = extract_json_section(json, "fixed_lot");
        if (fixed_lot_str.empty()) {
            fixed_lot_str = extract_json_section(json, "fixedLot");
        }
        if (!fixed_lot_str.empty()) {
            try {
                config.fixed_lot = std::stod(fixed_lot_str);
            } catch (...) {
                config.fixed_lot = 0.0;
            }
        }
    }
    if (json_object_has_any_key(json, "reverse_trading", "reverseTrading")) {
        std::string reverse_str = extract_json_section(json, "reverse_trading");
        if (reverse_str.empty()) {
            reverse_str = extract_json_section(json, "reverseTrading");
        }
        if (!reverse_str.empty()) {
            config.reverse_trading = (reverse_str == "true" || reverse_str == "1");
        }
    }
    if (json_object_has_any_key(json, "exact_match", "exactMatch")) {
        std::string exact_match_str = extract_json_section(json, "exact_match");
        if (exact_match_str.empty()) {
            exact_match_str = extract_json_section(json, "exactMatch");
        }
        if (!exact_match_str.empty()) {
            config.exact_match = (exact_match_str == "true" || exact_match_str == "1");
        }
    }
    if (json_object_has_key(json, "prefix")) {
        std::string prefix_obj = extract_json_section(json, "prefix");
        if (!prefix_obj.empty() && prefix_obj[0] == '{') {
            std::string prefix_enabled = extract_json_section(prefix_obj, "enabled");
            config.prefix.enabled = (prefix_enabled == "true" || prefix_enabled == "1");
            config.prefix.value = extract_json_string_value(prefix_obj, "value");
            config.prefix.action = extract_json_string_value(prefix_obj, "action");
        }
        if (config.prefix.action.empty()) {
            config.prefix.action = "add";
        }
    }
    if (json_object_has_key(json, "suffix")) {
        std::string suffix_obj = extract_json_section(json, "suffix");
        if (!suffix_obj.empty() && suffix_obj[0] == '{') {
            std::string suffix_enabled = extract_json_section(suffix_obj, "enabled");
            config.suffix.enabled = (suffix_enabled == "true" || suffix_enabled == "1");
            config.suffix.value = extract_json_string_value(suffix_obj, "value");
            config.suffix.action = extract_json_string_value(suffix_obj, "action");
        }
        if (config.suffix.action.empty()) {
            config.suffix.action = "add";
        }
    }
    if (json_object_has_any_key(json, "symbolTranslations", "symbol_translations")) {
        config.symbol_translations.clear();
        std::string array_str = extract_json_section(json, "symbolTranslations");
        if (array_str.empty()) {
            array_str = extract_json_section(json, "symbol_translations");
        }
        if (!array_str.empty() && array_str[0] == '[') {
            std::string array_content = array_str.substr(1);
            if (!array_content.empty() && array_content.back() == ']') {
                array_content.pop_back();
            }
            size_t pos = 0;
            while (pos < array_content.length()) {
                while (pos < array_content.length() && std::isspace(static_cast<unsigned char>(array_content[pos]))) {
                    pos++;
                }
                if (pos >= array_content.length()) break;
                if (array_content[pos] == ',') {
                    pos++;
                    continue;
                }
                if (array_content[pos] == '"') {
                    size_t start = pos + 1;
                    size_t end = start;
                    bool escape = false;
                    while (end < array_content.length()) {
                        char ch = array_content[end];
                        if (escape) {
                            escape = false;
                            end++;
                            continue;
                        }
                        if (ch == '\\') {
                            escape = true;
                            end++;
                            continue;
                        }
                        if (ch == '"') {
                            std::string translation = array_content.substr(start, end - start);
                            if (!translation.empty()) {
                                config.symbol_translations.push_back(translation);
                            }
                            pos = end + 1;
                            break;
                        }
                        end++;
                    }
                    if (end >= array_content.length()) break;
                } else {
                    size_t next_comma = array_content.find(',', pos);
                    if (next_comma != std::string::npos) {
                        pos = next_comma + 1;
                    } else {
                        break;
                    }
                }
            }
        }
    }
    return config;
}

AccountConfig BridgeServer::parse_config_json(const std::string& json, const char* source) {
    (void)source;
    AccountConfig config;
    config.role = extract_json_string_value(json, "role");
    
    config.master_tcp_url = extract_json_string_value(json, "master_tcp_url");
    if (config.master_tcp_url.empty()) {
        config.master_tcp_url = extract_json_string_value(json, "masterTcpUrl");
    }
    
    config.lot_type = extract_json_string_value(json, "lot_type");
    if (config.lot_type.empty()) {
        config.lot_type = extract_json_string_value(json, "lotType");
    }
    if (config.lot_type.empty()) {
        config.lot_type = "multiplier";
    }
    if (config.lot_type == "fixedlot") {
        config.lot_type = "fixed";
    }
    
    std::string lot_mult_str = extract_json_section(json, "lot_multiplier");
    if (lot_mult_str.empty()) {
        lot_mult_str = extract_json_section(json, "lotMultiplier");
    }
    if (!lot_mult_str.empty()) {
        try {
            config.lot_multiplier = std::stod(lot_mult_str);
        } catch (...) {
            config.lot_multiplier = 1.0;
        }
    }
    
    std::string fixed_lot_str = extract_json_section(json, "fixed_lot");
    if (fixed_lot_str.empty()) {
        fixed_lot_str = extract_json_section(json, "fixedLot");
    }
    if (!fixed_lot_str.empty()) {
        try {
            config.fixed_lot = std::stod(fixed_lot_str);
        } catch (...) {
            config.fixed_lot = 0.0;
        }
    }
    
    std::string reverse_str = extract_json_section(json, "reverse_trading");
    if (reverse_str.empty()) {
        reverse_str = extract_json_section(json, "reverseTrading");
    }
    if (!reverse_str.empty()) {
        config.reverse_trading = (reverse_str == "true" || reverse_str == "1");
    }

    std::string exact_match_str = extract_json_section(json, "exact_match");
    if (exact_match_str.empty()) {
        exact_match_str = extract_json_section(json, "exactMatch");
    }
    if (!exact_match_str.empty()) {
        config.exact_match = (exact_match_str == "true" || exact_match_str == "1");
    }

    std::string prefix_obj = extract_json_section(json, "prefix");
    if (!prefix_obj.empty() && prefix_obj[0] == '{') {
        std::string prefix_enabled = extract_json_section(prefix_obj, "enabled");
        config.prefix.enabled = (prefix_enabled == "true" || prefix_enabled == "1");
        config.prefix.value = extract_json_string_value(prefix_obj, "value");
        config.prefix.action = extract_json_string_value(prefix_obj, "action");
    } else {
        std::string prefix_enabled = extract_json_section(json, "prefix_enabled");
        config.prefix.enabled = (prefix_enabled == "true" || prefix_enabled == "1");
        config.prefix.value = extract_json_string_value(json, "prefix_value");
        config.prefix.action = extract_json_string_value(json, "prefix_action");
    }
    if (config.prefix.action.empty()) {
        config.prefix.action = "add";
    }

    std::string suffix_obj = extract_json_section(json, "suffix");
    if (!suffix_obj.empty() && suffix_obj[0] == '{') {
        std::string suffix_enabled = extract_json_section(suffix_obj, "enabled");
        config.suffix.enabled = (suffix_enabled == "true" || suffix_enabled == "1");
        config.suffix.value = extract_json_string_value(suffix_obj, "value");
        config.suffix.action = extract_json_string_value(suffix_obj, "action");
    } else {
        std::string suffix_enabled = extract_json_section(json, "suffix_enabled");
        config.suffix.enabled = (suffix_enabled == "true" || suffix_enabled == "1");
        config.suffix.value = extract_json_string_value(json, "suffix_value");
        config.suffix.action = extract_json_string_value(json, "suffix_action");
    }
    if (config.suffix.action.empty()) {
        config.suffix.action = "add";
    }

    std::string array_str = extract_json_section(json, "symbolTranslations");
    if (array_str.empty()) {
        array_str = extract_json_section(json, "symbol_translations");
    }

    if (!array_str.empty() && array_str[0] == '[') {
        std::string array_content = array_str.substr(1);
        if (!array_content.empty() && array_content.back() == ']') {
            array_content.pop_back();
        }

        size_t pos = 0;
        while (pos < array_content.length()) {
            while (pos < array_content.length() && std::isspace(static_cast<unsigned char>(array_content[pos]))) {
                pos++;
            }
            if (pos >= array_content.length()) break;

            if (array_content[pos] == ',') {
                pos++;
                continue;
            }

            if (array_content[pos] == '"') {
                size_t start = pos + 1;
                size_t end = start;
                bool escape = false;

                while (end < array_content.length()) {
                    char ch = array_content[end];
                    if (escape) {
                        escape = false;
                        end++;
                        continue;
                    }
                    if (ch == '\\') {
                        escape = true;
                        end++;
                        continue;
                    }
                    if (ch == '"') {
                        std::string translation = array_content.substr(start, end - start);
                        if (!translation.empty()) {
                            config.symbol_translations.push_back(translation);
                        }
                        pos = end + 1;
                        break;
                    }
                    end++;
                }

                if (end >= array_content.length()) {
                    break;
                }
            } else {
                size_t next_comma = array_content.find(',', pos);
                if (next_comma != std::string::npos) {
                    pos = next_comma + 1;
                } else {
                    break;
                }
            }
        }
    }

    return config;
}

std::string BridgeServer::config_to_json(const AccountConfig& config) {
    std::ostringstream ss;
    ss << "{";
    ss << "\"role\":\"" << json_escape(config.role) << "\",";
    ss << "\"master_tcp_url\":";
    if (config.master_tcp_url.empty()) {
        ss << "null";
    } else {
        ss << "\"" << json_escape(config.master_tcp_url) << "\"";
    }
    ss << ",";
    ss << "\"lot_type\":\"" << json_escape(config.lot_type) << "\",";
    ss << "\"lot_multiplier\":" << config.lot_multiplier << ",";
    ss << "\"fixed_lot\":" << config.fixed_lot << ",";
    ss << "\"reverse_trading\":" << (config.reverse_trading ? "true" : "false") << ",";
    ss << "\"exact_match\":" << (config.exact_match ? "true" : "false") << ",";
    ss << "\"prefix\":{";
    ss << "\"enabled\":" << (config.prefix.enabled ? "true" : "false") << ",";
    ss << "\"value\":";
    if (config.prefix.value.empty()) {
        ss << "null";
    } else {
        ss << "\"" << json_escape(config.prefix.value) << "\"";
    }
    ss << ",";
    ss << "\"action\":\"" << json_escape(config.prefix.action) << "\"";
    ss << "},";
    ss << "\"suffix\":{";
    ss << "\"enabled\":" << (config.suffix.enabled ? "true" : "false") << ",";
    ss << "\"value\":";
    if (config.suffix.value.empty()) {
        ss << "null";
    } else {
        ss << "\"" << json_escape(config.suffix.value) << "\"";
    }
    ss << ",";
    ss << "\"action\":\"" << json_escape(config.suffix.action) << "\"";
    ss << "},";
    ss << "\"symbol_translations\":[";
    for (size_t i = 0; i < config.symbol_translations.size(); ++i) {
        if (i > 0) ss << ",";
        ss << "\"" << json_escape(config.symbol_translations[i]) << "\"";
    }
    ss << "]";
    ss << "}";
    return ss.str();
}

static std::string decode_query_string(std::string query) {
    std::string out;
    out.reserve(query.size());
    for (size_t i = 0; i < query.size(); ++i) {
        if (query[i] == '%' && i + 2 < query.size()) {
            int hi = -1, lo = -1;
            char c1 = query[i + 1], c2 = query[i + 2];
            if (c1 >= '0' && c1 <= '9') hi = c1 - '0';
            else if (c1 >= 'A' && c1 <= 'F') hi = c1 - 'A' + 10;
            else if (c1 >= 'a' && c1 <= 'f') hi = c1 - 'a' + 10;
            if (c2 >= '0' && c2 <= '9') lo = c2 - '0';
            else if (c2 >= 'A' && c2 <= 'F') lo = c2 - 'A' + 10;
            else if (c2 >= 'a' && c2 <= 'f') lo = c2 - 'a' + 10;
            if (hi >= 0 && lo >= 0) {
                out += static_cast<char>((hi << 4) | lo);
                i += 2;
                continue;
            }
        }
        out += query[i];
    }
    return out;
}

static std::string get_query_param(const std::string& query, const std::string& key) {
    if (query.empty()) return "";
    size_t pos = 0;
    while (pos < query.size()) {
        size_t amp = query.find('&', pos);
        std::string pair = (amp != std::string::npos) ? query.substr(pos, amp - pos) : query.substr(pos);
        size_t eq = pair.find('=');
        if (eq != std::string::npos) {
            std::string k = pair.substr(0, eq);
            std::string v = pair.substr(eq + 1);
            if (k == key) return v;
        }
        if (amp == std::string::npos) break;
        pos = amp + 1;
    }
    return "";
}

static int count_top_level_json_objects(const std::string& json_array) {
    if (json_array.empty() || json_array.front() != '[') {
        return 0;
    }
    int count = 0;
    int brace_depth = 0;
    int bracket_depth = 0;
    bool in_string = false;
    bool escape = false;
    for (char ch : json_array) {
        if (in_string) {
            if (escape) {
                escape = false;
            } else if (ch == '\\') {
                escape = true;
            } else if (ch == '"') {
                in_string = false;
            }
            continue;
        }
        if (ch == '"') {
            in_string = true;
            continue;
        }
        if (ch == '[') {
            ++bracket_depth;
            continue;
        }
        if (ch == ']') {
            --bracket_depth;
            continue;
        }
        if (ch == '{') {
            if (bracket_depth == 1 && brace_depth == 0) {
                ++count;
            }
            ++brace_depth;
            continue;
        }
        if (ch == '}') {
            --brace_depth;
            continue;
        }
    }
    return (count < 0) ? 0 : count;
}

static void send_http_response_raw(SOCKET client_socket, const HttpResponse& response) {
    std::ostringstream builder;
    builder << "HTTP/1.1 " << response.status << " ";
    builder << (response.status == 200 ? "OK" : "ERROR") << "\r\n";
    builder << "Content-Type: " << response.content_type << "\r\n";
    builder << "Content-Length: " << response.body.size() << "\r\n";
    builder << "Connection: close\r\n";
    for (const auto& [header, value] : response.headers) {
        builder << header << ": " << value << "\r\n";
    }
    builder << "\r\n";
    builder << response.body;

    std::string payload = builder.str();
    size_t sent_total = 0;
    while (sent_total < payload.size()) {
        int sent = send(client_socket, payload.c_str() + sent_total, static_cast<int>(payload.size() - sent_total), 0);
        if (sent <= 0) {
            break;
        }
        sent_total += static_cast<size_t>(sent);
    }
}

void BridgeServer::update_live_metrics_from_snapshot(const std::string& account_id, const std::string& snapshot_json) {
    LiveMetrics next;
    {
        std::lock_guard<std::mutex> lock(live_metrics_mutex_);
        next = live_metrics_;
    }

    next.account_id = account_id.empty() ? "0" : account_id;
    next.updated_unix = static_cast<std::int64_t>(std::time(nullptr));

    bool parsed_open_count = false;
    std::string open_count_raw = extract_json_numeric_or_null(snapshot_json, "open_positions_count");
    if (!open_count_raw.empty() && open_count_raw != "null") {
        try {
            next.open_orders = std::stoi(open_count_raw);
            parsed_open_count = true;
        } catch (...) {
        }
    }
    if (!parsed_open_count) {
        std::string positions_array = extract_json_section(snapshot_json, "open_positions");
        next.open_orders = count_top_level_json_objects(positions_array);
    }

    bool parsed_pending_count = false;
    std::string pending_count_raw = extract_json_numeric_or_null(snapshot_json, "pending_orders_count");
    if (!pending_count_raw.empty() && pending_count_raw != "null") {
        try {
            next.pending_orders = std::stoi(pending_count_raw);
            parsed_pending_count = true;
        } catch (...) {
        }
    }
    if (!parsed_pending_count) {
        std::string pending_array = extract_json_section(snapshot_json, "pending_orders");
        next.pending_orders = count_top_level_json_objects(pending_array);
    }

    {
        std::lock_guard<std::mutex> lock(live_metrics_mutex_);
        live_metrics_ = next;
    }

    {
        std::lock_guard<std::mutex> lock(orders_snapshot_mutex_);
        orders_snapshot_json_ = snapshot_json;
    }
}

bool BridgeServer::handle_ws_metrics_stream(const HttpRequest& request, SOCKET client_socket) {
    if (!has_valid_api_auth(request)) {
        HttpResponse response;
        response.status = 401;
        response.body = R"({"success":false,"error":{"code":"unauthorized","message":"Invalid or missing x-api-key / x-api-secret"},"data":null})";
        send_http_response_raw(client_socket, response);
        closesocket(client_socket);
        return true;
    }

    if (!HttpServer::send_websocket_handshake(request, client_socket)) {
        return false;
    }

    std::string requested_account = extract_account_id_from_path(request.path);
    if (requested_account.empty()) {
        requested_account = "0";
    }

    while (ready_) {
        LiveMetrics metrics;
        std::string snapshot_json;
        {
            std::lock_guard<std::mutex> lock(live_metrics_mutex_);
            metrics = live_metrics_;
        }
        {
            std::lock_guard<std::mutex> lock(orders_snapshot_mutex_);
            snapshot_json = orders_snapshot_json_;
        }

        bool account_matches = (requested_account == "0" || requested_account == metrics.account_id);

        std::string payload;
        if (account_matches && !snapshot_json.empty()) {
            // Forward the bot snapshot as-is. It already matches the shape the
            // IPTRADE Rust bridge expects (TcpSnapshotMessage) and is consistent
            // with the snapshot JSON that 5MTrader-API produces:
            //   { "event":"snapshot", "platform":"...", "account":{...},
            //     "open_positions":[...], "pending_orders":[...],
            //     "open_positions_count":N, "pending_orders_count":N }
            payload = snapshot_json;
        } else {
            std::ostringstream minimal;
            minimal << "{\"event\":\"snapshot\",\"account\":null,";
            minimal << "\"open_positions\":[],\"pending_orders\":[],";
            minimal << "\"open_positions_count\":0,\"pending_orders_count\":0}";
            payload = minimal.str();
        }

        if (!HttpServer::send_websocket_text(client_socket, payload)) {
            break;
        }
        std::this_thread::sleep_for(std::chrono::seconds(1));
    }

    closesocket(client_socket);
    return true;
}

HttpResponse BridgeServer::handle_post_config(const HttpRequest& request) {
    HttpResponse response;
    std::string account_id = extract_account_id_from_path(request.path);
    if (account_id.empty()) {
        response.status = 400;
        response.body = R"({"success":false,"error":"account_id is required"})";
        return response;
    }
    std::string inner = extract_json_section(request.body, "copyTradingConfig");
    if (inner.empty() || inner[0] != '{') {
        response.status = 400;
        response.body = R"({"success":false,"error":"Body must contain copyTradingConfig object"})";
        return response;
    }
    AccountConfig existing;
    bool has_existing = ConfigApi::instance().get_config(account_id, existing);
    if (!has_existing) {
        ConfigApi::instance().load_config_from_file(account_id);
        has_existing = ConfigApi::instance().get_config(account_id, existing);
    }
    AccountConfig config = has_existing
        ? parse_config_json_merge(inner, existing)
        : parse_config_json(inner, "POST copyTradingConfig");
    if (config.role.empty()) {
        response.status = 400;
        response.body = R"({"success":false,"error":"copyTradingConfig.role is required"})";
        return response;
    }
    std::string error_message;
    if (!ConfigApi::instance().validate_config(config, error_message)) {
        response.status = 400;
        response.body = wrap_response(false, "", error_message);
        return response;
    }
    bool was_master = has_existing && existing.is_master();
    if (ConfigApi::instance().set_config(account_id, config)) {
        auto tcp_result = update_tcp_client(account_id);
        if (was_master && !config.is_master()) {
            tcp_server_.disconnect_all_clients();
        }
        if (HeartbeatService::instance().get_account_id() == account_id) {
            int tcp_port = (config.is_master()) ? tcp_server_.assigned_port() : 0;
            HeartbeatService::instance().update_tcp_port(tcp_port);
        }
        if (config.is_master() && HeartbeatService::instance().get_account_id() == account_id) {
            send_ready_event_immediate();
            broadcast_last_snapshot_to_tcp_if_effective();
        }
        response.status = 200;
        bool ok = tcp_result.first;
        std::string err_msg;
        if (config.is_master()) {
            if (!tcp_connection_enabled_) {
                ok = true;
                err_msg = "";
            } else if (!tcp_server_.is_running()) {
                ok = false;
                err_msg = "TCP server not exposed";
            } else {
                err_msg = "";
            }
        } else {
            err_msg = ok ? "" : tcp_result.second;
        }
        response.body = wrap_response(ok, config_to_json(config), err_msg);
    } else {
        response.status = 500;
        response.body = wrap_response(false, "", "Failed to save configuration");
    }
    return response;
}

HttpResponse BridgeServer::handle_put_config(const HttpRequest& request) {
    HttpResponse response;
    std::string account_id = extract_account_id_from_path(request.path);
    if (account_id.empty()) {
        response.status = 400;
        response.body = R"({"success":false,"error":"account_id is required"})";
        return response;
    }
    
    if (request.body.empty()) {
        if (ConfigApi::instance().delete_config(account_id)) {
            remove_tcp_client(account_id);
            if (HeartbeatService::instance().get_account_id() == account_id) {
                HeartbeatService::instance().update_tcp_port(0);
            }
            response.status = 200;
            response.body = wrap_response(true, "", "");
        } else {
            response.status = 404;
            response.body = wrap_response(false, "", "Configuration not found");
        }
        return response;
    }
    
    AccountConfig existing_config;
    bool has_existing_config = ConfigApi::instance().get_config(account_id, existing_config);
    if (!has_existing_config) {
        ConfigApi::instance().load_config_from_file(account_id);
        has_existing_config = ConfigApi::instance().get_config(account_id, existing_config);
    }
    AccountConfig config = has_existing_config
        ? parse_config_json_merge(request.body, existing_config)
        : parse_config_json(request.body, "PUT body");
    if (config.role.empty()) {
        if (ConfigApi::instance().delete_config(account_id)) {
            remove_tcp_client(account_id);
            if (HeartbeatService::instance().get_account_id() == account_id) {
                HeartbeatService::instance().update_tcp_port(0);
            }
            response.status = 200;
            response.body = wrap_response(true, "", "");
        } else {
            response.status = 404;
            response.body = wrap_response(false, "", "Configuration not found");
        }
        return response;
    }
    
    std::string error_message;
    if (!ConfigApi::instance().validate_config(config, error_message)) {
        response.status = 400;
        response.body = wrap_response(false, "", error_message);
        return response;
    }
    
    bool was_master = has_existing_config && existing_config.is_master();
    if (ConfigApi::instance().set_config(account_id, config)) {
        auto tcp_result = update_tcp_client(account_id);
        if (was_master && !config.is_master()) {
            tcp_server_.disconnect_all_clients();
        }
        if (HeartbeatService::instance().get_account_id() == account_id) {
            int tcp_port = (config.is_master()) ? tcp_server_.assigned_port() : 0;
            HeartbeatService::instance().update_tcp_port(tcp_port);
        }
        if (config.is_master() && HeartbeatService::instance().get_account_id() == account_id) {
            send_ready_event_immediate();
            broadcast_last_snapshot_to_tcp_if_effective();
        }
        response.status = 200;
        bool ok = tcp_result.first;
        std::string err_msg;
        if (config.is_master()) {
            if (!tcp_connection_enabled_) {
                ok = true;
                err_msg = "";
            } else if (!tcp_server_.is_running()) {
                ok = false;
                err_msg = "TCP server not exposed";
            } else {
                err_msg = "";
            }
        } else {
            err_msg = ok ? "" : tcp_result.second;
        }
        response.body = wrap_response(ok, config_to_json(config), err_msg);
    } else {
        response.status = 500;
        response.body = wrap_response(false, "", "Failed to save configuration");
    }
    return response;
}

HttpResponse BridgeServer::handle_put_tcp(const HttpRequest& request) {
    HttpResponse response;
    std::string account_id = extract_account_id_from_path(request.path);
    if (account_id.empty()) {
        response.status = 400;
        response.body = R"({"success":false,"error":"account_id is required"})";
        return response;
    }
    std::string current_account = HeartbeatService::instance().get_account_id();
    if (current_account.empty()) {
        response.status = 503;
        response.body = wrap_response(false, "", "Account not connected");
        return response;
    }
    if (account_id != current_account) {
        response.status = 404;
        response.body = wrap_response(false, "", "Account not found");
        return response;
    }

    std::string query_string = request.query;
    if (query_string.empty()) {
        size_t q = request.path.find('?');
        if (q != std::string::npos && q + 1 < request.path.size()) {
            query_string = request.path.substr(q + 1);
        }
    }
    query_string = decode_query_string(query_string);
    std::string enabled_val = get_query_param(query_string, "enabled");
    if (enabled_val.empty()) {
        response.status = 400;
        response.body = wrap_response(false, "", "Query parameter 'enabled' is required (true or false)");
        return response;
    }
    bool enable = (enabled_val == "true" || enabled_val == "1");

    // Toggling TCP enabled keeps the underlying connections alive on both sides:
    //   - master keeps the TCP server up and existing slave sessions connected,
    //     it just stops broadcasting events while disabled
    //   - slave keeps its TCP client connected to the master and just drops any
    //     incoming events while disabled
    // Connections are only torn down by config/role changes, not by this toggle.
    tcp_connection_enabled_ = enable;

    if (enable) {
        AccountConfig config;
        if (ConfigApi::instance().get_config(account_id, config) && config.is_master()) {
            send_ready_event_immediate();
            broadcast_last_snapshot_to_tcp_if_effective();
        }
    }

    response.status = 200;
    response.body = wrap_response(true, "", "");
    return response;
}

std::pair<bool, std::string> BridgeServer::update_tcp_client(const std::string& account_id) {
    // Connection lifecycle is driven by role/config only. The tcp_connection_enabled_
    // flag gates *event flow* (master broadcast, slave inbound processing) but the
    // socket itself stays connected so toggling it on/off does not require a reconnect.
    AccountConfig config;
    if (!ConfigApi::instance().get_config(account_id, config)) {
        remove_tcp_client(account_id);
        return { true, "" };
    }
    if (!config.is_slave()) {
        remove_tcp_client(account_id);
        return { true, "" };
    }
    if (config.master_tcp_url.empty()) {
        remove_tcp_client(account_id);
        return { true, "" };
    }

    std::lock_guard<std::mutex> lock(tcp_clients_mutex_);
    auto it = tcp_clients_.find(account_id);
    if (it != tcp_clients_.end()) {
        if (it->second->is_connected() && it->second->get_connected_url() == config.master_tcp_url) {
            return { true, "" };
        }
        it->second->disconnect();
        it->second.reset(new TcpClient());
        if (it->second->connect(config.master_tcp_url, account_id)) {
            return { true, "" };
        }
        return { false, it->second->get_status() };
    }

    auto client = std::make_unique<TcpClient>();
    if (client->connect(config.master_tcp_url, account_id)) {
        tcp_clients_[account_id] = std::move(client);
        return { true, "" };
    }
    std::string err = client->get_status();
    tcp_clients_[account_id] = std::move(client);
    return { false, err };
}

std::string BridgeServer::get_connected_master_tcp_url(const std::string& account_id) const {
    AccountConfig config;
    if (!ConfigApi::instance().get_config(account_id, config)
        || !config.is_slave() || config.master_tcp_url.empty()) {
        return "";
    }
    return config.master_tcp_url;
}

void BridgeServer::remove_tcp_client(const std::string& account_id) {
    std::lock_guard<std::mutex> lock(tcp_clients_mutex_);
    auto it = tcp_clients_.find(account_id);
    if (it != tcp_clients_.end()) {
        it->second->disconnect();
        tcp_clients_.erase(it);
    }
}

static constexpr int TCP_SLAVE_RECONNECT_INTERVAL_SECONDS = 5;

void BridgeServer::tcp_clients_maintenance_loop() {
    while (maintenance_running_) {
        std::this_thread::sleep_for(std::chrono::seconds(TCP_SLAVE_RECONNECT_INTERVAL_SECONDS));
        
        if (!maintenance_running_) break;
        // Reconnect dropped slave sockets even when tcp_connection_enabled_ is false
        // so toggling it back on is instantaneous (the connection is already live).
        std::vector<std::string> account_ids = ConfigApi::instance().get_all_account_ids();
        for (const auto& account_id : account_ids) {
            if (!maintenance_running_) break;
            
            AccountConfig config;
            if (!ConfigApi::instance().get_config(account_id, config)) {
                continue;
            }
            
            if (!config.is_slave() || config.master_tcp_url.empty()) {
                continue;
            }
            
            std::lock_guard<std::mutex> lock(tcp_clients_mutex_);
            auto it = tcp_clients_.find(account_id);
            if (it != tcp_clients_.end()) {
                if (!it->second->is_connected()) {
                    it->second->disconnect();
                    it->second.reset(new TcpClient());
                    it->second->connect(config.master_tcp_url, account_id);
                }
            } else {
                auto client = std::make_unique<TcpClient>();
                if (client->connect(config.master_tcp_url, account_id)) {
                    tcp_clients_[account_id] = std::move(client);
                } else {
                    tcp_clients_[account_id] = std::move(client);
                }
            }
        }
    }
}

}

