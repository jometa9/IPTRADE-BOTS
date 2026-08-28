#pragma once

#include <atomic>
#include <chrono>
#include <future>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>
#include <cstdint>

#include "BridgeTypes.h"
#include "CommandQueue.h"
#include "HttpServer.h"
#include "LocalEventPoster.h"
#include "ConfigApi.h"
#include "HeartbeatService.h"
#include "TcpServer.h"
#include "TcpClient.h"

namespace bridge {

class BridgeServer {
public:
    static BridgeServer& instance();

    int init(const std::string& external_url,
             int min_port,
             int max_port,
             const std::string& encryption_key = "");
    void stop();

    int poll_next_command(char* buffer, int buffer_len);
    int ack_command(long command_id, int result_code, const std::string& message, const std::string& data_json);
    int push_local_event(const std::string& json_event);
    int send_ready_notification(const std::string& account_json, int local_port);
    int assigned_port() const;
    void queue_command(const std::string& command_json);
    bool is_tcp_connection_enabled() const { return tcp_connection_enabled_.load(); }

private:
    BridgeServer() = default;
    ~BridgeServer();

    void register_routes();
    HttpResponse handle_put_config(const HttpRequest& request);
    HttpResponse handle_put_tcp(const HttpRequest& request);
    HttpResponse handle_post_config(const HttpRequest& request);
    static std::string extract_account_id_from_path(const std::string& path);
    static AccountConfig parse_config_json(const std::string& json, const char* source = nullptr);
    static AccountConfig parse_config_json_merge(const std::string& json, const AccountConfig& base);
    static std::string config_to_json(const AccountConfig& config);
    static bool has_valid_api_auth(const HttpRequest& req);
    static bool parse_json_bool(const std::string& source, const std::string& key, bool* value_out, bool* key_present_out = nullptr);
    static bool parse_json_long(const std::string& source, const std::string& key, long* value_out, bool* key_present_out = nullptr);
    static bool parse_json_double(const std::string& source, const std::string& key, double* value_out, bool* key_present_out = nullptr);
    static bool parse_json_nullable_double(const std::string& source, const std::string& key, double* value_out, bool* key_present_out = nullptr, bool* is_null_out = nullptr);
    static bool parse_json_nullable_string(const std::string& source, const std::string& key, std::string* value_out, bool* key_present_out = nullptr, bool* is_null_out = nullptr);
    std::string wrap_response(bool success, const std::string& data, const std::string& error_message) const;
    static std::string extract_json_section(const std::string& source, const std::string& key);
    static std::string extract_json_string_value(const std::string& source, const std::string& key);
    static std::string extract_json_numeric_or_null(const std::string& source, const std::string& key);
    static std::string simplify_event_json(const std::string& json_event);
    void update_live_metrics_from_snapshot(const std::string& account_id, const std::string& snapshot_json);
    bool handle_ws_metrics_stream(const HttpRequest& request, SOCKET client_socket);

    bool http_post_sync(const std::string& url, const std::string& body,
                        std::string& response_out);

    struct PendingAck {
        std::promise<std::string> promise;
    };

    CommandQueue queue_;
    HttpServer server_;
    LocalEventPoster local_event_poster_;
    TcpServer tcp_server_;

    std::atomic<long> next_command_id_{1};
    std::atomic<bool> ready_{false};
    std::atomic<int> assigned_port_{0};
    std::atomic<bool> tcp_connection_enabled_{true};
    int tcp_min_port_{0};
    int tcp_max_port_{0};

    std::string external_url_;

    std::mutex pending_mutex_;
    std::unordered_map<long, std::shared_ptr<PendingAck>> pending_acks_;

    mutable std::mutex tcp_clients_mutex_;
    std::unordered_map<std::string, std::unique_ptr<TcpClient>> tcp_clients_;
    std::thread tcp_clients_maintenance_thread_;
    std::atomic<bool> maintenance_running_{false};

    std::pair<bool, std::string> update_tcp_client(const std::string& account_id);
    void remove_tcp_client(const std::string& account_id);
    void tcp_clients_maintenance_loop();
    std::string get_connected_master_tcp_url(const std::string& account_id) const;
    void send_ready_event_immediate();
    void on_new_tcp_session(const std::string& account_id);
    void broadcast_last_snapshot_to_tcp_if_effective();

    std::mutex last_snapshot_mutex_;
    std::string last_snapshot_json_;

    std::mutex orders_snapshot_mutex_;
    std::string orders_snapshot_json_;

    struct LiveMetrics {
        std::string account_id = "0";
        int open_orders = 0;
        int pending_orders = 0;
        std::int64_t updated_unix = 0;
    };
    std::mutex live_metrics_mutex_;
    LiveMetrics live_metrics_;
};

}
