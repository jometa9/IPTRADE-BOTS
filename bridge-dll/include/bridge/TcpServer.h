#pragma once

#include <string>
#include <unordered_map>
#include <mutex>
#include <thread>
#include <atomic>
#include <functional>
#include <winsock2.h>
#include <ws2tcpip.h>

#pragma comment(lib, "Ws2_32.lib")

namespace bridge {

struct TcpClientSession {
    std::string session_id;
    std::string account_id;
    SOCKET socket;
    bool connected;
    std::thread handler_thread;
};

class TcpServer {
public:
    TcpServer();
    ~TcpServer();

    bool start(int min_port, int max_port);
    void stop();

    int assigned_port() const { return assigned_port_; }
    bool is_running() const { return running_; }

    void broadcast_event(const std::string& account_id, const std::string& json_event);
    void broadcast_to_all(const std::string& json_event);
    bool has_clients_for_account(const std::string& account_id) const;
    void disconnect_clients_for_account(const std::string& account_id);
    void disconnect_all_clients();
    void set_on_new_session_callback(std::function<void(const std::string& account_id)> cb);

private:
    void accept_loop();
    void handle_client(SOCKET client_socket);
    void client_handler_thread(SOCKET client_socket);
    bool receive_connection_account_id(SOCKET client_socket, std::string& account_id_out);
    void receive_commands_loop(SOCKET client_socket, const std::string& account_id);
    void process_command(SOCKET client_socket, const std::string& account_id, const std::string& json_command);
    void send_response(SOCKET client_socket, const std::string& json_response);
    int find_available_port(int min_port, int max_port);

    std::atomic<bool> running_{false};
    std::atomic<int> assigned_port_{0};
    SOCKET listen_socket_{INVALID_SOCKET};
    std::thread accept_thread_;

    mutable std::mutex sessions_mutex_;
    std::unordered_map<std::string, std::shared_ptr<TcpClientSession>> sessions_;

    std::mutex on_new_session_mutex_;
    std::function<void(const std::string& account_id)> on_new_session_callback_;

    std::string generate_session_id() const;
};

}
