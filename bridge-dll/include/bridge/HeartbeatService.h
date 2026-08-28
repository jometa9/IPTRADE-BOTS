#pragma once

#include <string>
#include <thread>
#include <atomic>
#include <mutex>
#include <chrono>
#include <functional>

namespace bridge {

class HeartbeatService {
public:
    static HeartbeatService& instance();

    void set_current_account(const std::string& account_id, const std::string& account_json);
    void start(const std::string& account_id,
               const std::string& account_json,
               int local_port,
               int tcp_port,
               const std::string& heartbeat_url = "",
               std::function<std::string()> get_master_tcp_url = nullptr,
               std::function<std::string()> get_copy_config_json = nullptr);
    void stop();
    void update_account_info(const std::string& account_json, int local_port, int tcp_port);
    void update_tcp_port(int tcp_port);
    void mark_snapshot_activity();
    void set_terminal_connected(bool connected);
    std::string get_account_id() const;
    std::string get_account_server(const std::string& account_id) const;
    std::string get_account_json() const;
    int get_local_port() const;

private:
    HeartbeatService() = default;
    ~HeartbeatService();
    HeartbeatService(const HeartbeatService&) = delete;
    HeartbeatService& operator=(const HeartbeatService&) = delete;

    void heartbeat_loop();
    void send_heartbeat();
    std::string build_form_data();
    bool should_send_heartbeat() const;

    static constexpr int HEARTBEAT_INTERVAL_SECONDS = 10;
    static constexpr int BOT_HEARTBEAT_EXPECTED_SECONDS = 5;
    static constexpr int BOT_HEARTBEAT_MISS_TOLERANCE_SECONDS = 5;
    static constexpr int BOT_HEARTBEAT_TIMEOUT_SECONDS =
        BOT_HEARTBEAT_EXPECTED_SECONDS + BOT_HEARTBEAT_MISS_TOLERANCE_SECONDS;

    std::atomic<bool> running_{false};
    std::thread heartbeat_thread_;

    mutable std::mutex data_mutex_;
    std::string account_id_;
    std::string account_json_;
    int local_port_ = 0;
    int tcp_port_ = 0;
    std::string heartbeat_url_;
    std::function<std::string()> get_master_tcp_url_;
    std::function<std::string()> get_copy_config_json_;
    bool has_snapshot_activity_ = false;
    std::chrono::steady_clock::time_point last_snapshot_activity_;
    std::string cached_public_ip_;
    std::chrono::steady_clock::time_point last_ip_check_;
    static constexpr std::chrono::hours IP_CACHE_DURATION{1};
    std::atomic<bool> terminal_connected_{true};
};

}
