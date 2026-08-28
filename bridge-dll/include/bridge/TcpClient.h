#pragma once

#include <string>
#include <atomic>
#include <thread>
#include <mutex>
#include <winsock2.h>
#include <ws2tcpip.h>

#pragma comment(lib, "Ws2_32.lib")

namespace bridge {

class TcpClient {
public:
    TcpClient();
    ~TcpClient();

    bool connect(const std::string& master_tcp_url, const std::string& slave_account_id);
    void disconnect();
    bool is_connected() const { return connected_; }
    std::string get_status() const;
    std::string get_connected_url() const;

private:
    bool parse_tcp_url(const std::string& url, std::string& host, int& port, std::string& account_id);
    bool send_connection_account_id(SOCKET socket, const std::string& account_id_to_send);
    void receive_events_loop();
    void process_event(const std::string& json_event);

    std::atomic<bool> running_{false};
    std::atomic<bool> connected_{false};
    SOCKET socket_{INVALID_SOCKET};
    std::thread receive_thread_;

    std::string master_host_;
    int master_port_;
    std::string master_account_id_;
    std::string slave_account_id_;
    std::string connected_url_;
    std::string leftover_after_handshake_;

    mutable std::mutex status_mutex_;
    std::string status_message_;
};

}
