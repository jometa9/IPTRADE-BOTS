#include "Bridge/TcpClient.h"
#include "Bridge/BridgeServer.h"
#include "Bridge/ConfigApi.h"
#include "Bridge/SlaveConverter.h"
#include <sstream>
#include <algorithm>
#include <chrono>
#include <string>
#include <atomic>
#include <mutex>
#include <windows.h>
#include <mstcpip.h>
#include <shlwapi.h>
#include <direct.h>

#pragma comment(lib, "shlwapi.lib")

namespace bridge {

TcpClient::TcpClient() {
    WSADATA wsaData;
    WSAStartup(MAKEWORD(2, 2), &wsaData);
}

TcpClient::~TcpClient() {
    disconnect();
    WSACleanup();
}

bool TcpClient::parse_tcp_url(const std::string& url, std::string& host, int& port, std::string& account_id) {
    if (url.length() < 7 || url.substr(0, 6) != "tcp://") {
        return false;
    }
    
    size_t host_start = 6; 
    size_t port_start = url.find(':', host_start);
    if (port_start == std::string::npos) {
        return false;
    }
    
    host = url.substr(host_start, port_start - host_start);
    
    size_t account_start = url.find('/', port_start);
    if (account_start == std::string::npos) {
        return false;
    }
    
    std::string port_str = url.substr(port_start + 1, account_start - port_start - 1);
    try {
        port = std::stoi(port_str);
    } catch (...) {
        return false;
    }
    
    account_id = url.substr(account_start + 1);
    
    return !host.empty() && port > 0 && port < 65536;
}

bool TcpClient::send_connection_account_id(SOCKET socket, const std::string& account_id_to_send) {
    std::string str = account_id_to_send + "\n";
    int sent = send(socket, str.c_str(), static_cast<int>(str.size()), 0);
    if (sent <= 0 || static_cast<size_t>(sent) != str.size()) {
        return false;
    }
    std::string response;
    response.reserve(512);
    char buf[256];
    const int timeout_sec = 5;
    auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(timeout_sec);
    while (response.find('\n') == std::string::npos) {
        if (std::chrono::steady_clock::now() > deadline) {
            return false;
        }
        fd_set read_set;
        FD_ZERO(&read_set);
        FD_SET(socket, &read_set);
        timeval tv;
        tv.tv_sec = 1;
        tv.tv_usec = 0;
        if (select(0, &read_set, nullptr, nullptr, &tv) <= 0 || !FD_ISSET(socket, &read_set)) {
            continue;
        }
        int n = recv(socket, buf, sizeof(buf) - 1, 0);
        if (n <= 0) {
            return false;
        }
        buf[n] = '\0';
        response.append(buf);
    }
    size_t first_newline = response.find('\n');
    std::string line = response.substr(0, first_newline);
    if (first_newline + 1 < response.size()) {
        leftover_after_handshake_ = response.substr(first_newline + 1);
    }
    bool ok = (line.find("\"status\":\"ready\"") != std::string::npos)
        || (line.find("\"status\": \"ready\"") != std::string::npos)
        || (line.find("\"status\":\"connected\"") != std::string::npos)
        || (line.find("\"status\": \"connected\"") != std::string::npos)
        || (line.find("'status': 'connected'") != std::string::npos)
        || (line.find("status") != std::string::npos && (line.find("connected") != std::string::npos || line.find("ready") != std::string::npos));
    return ok;
}

bool TcpClient::connect(const std::string& master_tcp_url, const std::string& slave_account_id) {
    if (receive_thread_.joinable() || connected_ || running_) {
        running_ = false;
        connected_ = false;
        if (socket_ != INVALID_SOCKET) {
            shutdown(socket_, SD_BOTH);
            closesocket(socket_);
            socket_ = INVALID_SOCKET;
        }
        if (receive_thread_.joinable()) {
            receive_thread_.join();
        }
    }
    
    if (master_tcp_url.empty() || slave_account_id.empty()) {
        {
            std::lock_guard<std::mutex> lock(status_mutex_);
            status_message_ = "Invalid parameters";
        }
        return false;
    }
    leftover_after_handshake_.clear();

    std::string host;
    int port;
    std::string account_id;
    if (!parse_tcp_url(master_tcp_url, host, port, account_id)) {
        {
            std::lock_guard<std::mutex> lock(status_mutex_);
            status_message_ = "Invalid TCP URL format";
        }
        return false;
    }
    
    master_host_ = host;
    master_port_ = port;
    master_account_id_ = account_id;
    slave_account_id_ = slave_account_id;

    socket_ = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (socket_ == INVALID_SOCKET) {
        {
            std::lock_guard<std::mutex> lock(status_mutex_);
            status_message_ = "Failed to create socket";
        }
        return false;
    }
    
    addrinfo hints{};
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_protocol = IPPROTO_TCP;
    
    addrinfo* result = nullptr;
    std::string port_str = std::to_string(port);
    int getaddrinfo_result = getaddrinfo(host.c_str(), port_str.c_str(), &hints, &result);
    
    if (getaddrinfo_result != 0 || result == nullptr) {
        closesocket(socket_);
        socket_ = INVALID_SOCKET;
        {
            std::lock_guard<std::mutex> lock(status_mutex_);
            status_message_ = "Failed to resolve hostname";
        }
        return false;
    }
    
    int connect_result = ::connect(socket_, result->ai_addr, static_cast<int>(result->ai_addrlen));
    freeaddrinfo(result);
    
    if (connect_result == SOCKET_ERROR) {
        int error = WSAGetLastError();
        closesocket(socket_);
        socket_ = INVALID_SOCKET;
        std::string err_msg;
        {
            std::lock_guard<std::mutex> lock(status_mutex_);
            if (error == WSAECONNREFUSED) {
                status_message_ = "Connection refused - master TCP server may not be running";
            } else if (error == WSAETIMEDOUT) {
                status_message_ = "Connection timeout";
            } else {
                status_message_ = "Failed to connect to master (error: " + std::to_string(error) + ")";
            }
            err_msg = status_message_;
        }
        return false;
    }
    
    if (!send_connection_account_id(socket_, master_account_id_)) {
        closesocket(socket_);
        socket_ = INVALID_SOCKET;
        {
            std::lock_guard<std::mutex> lock(status_mutex_);
            status_message_ = "Connection setup failed (no ready response)";
        }
        return false;
    }
    
    BOOL keepAlive = TRUE;
    setsockopt(socket_, SOL_SOCKET, SO_KEEPALIVE, reinterpret_cast<const char*>(&keepAlive), sizeof(keepAlive));

    tcp_keepalive ka{};
    ka.onoff = 1;
    ka.keepalivetime = 30000;
    ka.keepaliveinterval = 5000;
    DWORD bytesReturned = 0;
    WSAIoctl(socket_, SIO_KEEPALIVE_VALS, &ka, sizeof(ka),
             nullptr, 0, &bytesReturned, nullptr, nullptr);

    u_long mode = 0;
    ioctlsocket(socket_, FIONBIO, &mode);
    connected_ = true;
    running_ = true;
    connected_url_ = master_tcp_url;

    {
        std::lock_guard<std::mutex> lock(status_mutex_);
        status_message_ = "Connected to master";
    }

    receive_thread_ = std::thread(&TcpClient::receive_events_loop, this);
    
    return true;
}

void TcpClient::disconnect() {
    std::string sid = slave_account_id_;
    running_ = false;
    connected_ = false;
    
    if (socket_ != INVALID_SOCKET) {
        shutdown(socket_, SD_BOTH);
        closesocket(socket_);
        socket_ = INVALID_SOCKET;
    }
    
    if (receive_thread_.joinable()) {
        receive_thread_.join();
    }
    
    {
        std::lock_guard<std::mutex> lock(status_mutex_);
        status_message_ = "Disconnected";
    }
}

std::string TcpClient::get_status() const {
    std::lock_guard<std::mutex> lock(status_mutex_);
    return status_message_;
}

std::string TcpClient::get_connected_url() const {
    return connected_url_;
}

void TcpClient::receive_events_loop() {
    try {
        char buffer[8192];
        std::string message_buffer;
        if (!leftover_after_handshake_.empty()) {
            message_buffer = std::move(leftover_after_handshake_);
            leftover_after_handshake_.clear();
        }

        while (running_ && connected_) {
            while (!message_buffer.empty()) {
                size_t newline_pos = message_buffer.find('\n');
                if (newline_pos == std::string::npos) break;
                std::string line = message_buffer.substr(0, newline_pos);
                message_buffer = message_buffer.substr(newline_pos + 1);
                size_t i = 0;
                while (i < line.size() && (line[i] == ' ' || line[i] == '\t' || line[i] == '\r')) i++;
                size_t j = line.size();
                while (j > i && (line[j-1] == ' ' || line[j-1] == '\t' || line[j-1] == '\r')) j--;
                line = line.substr(i, j - i);
                if (line.empty() || line[0] != '{') continue;

                try {
                    process_event(line);
                } catch (const std::exception& ex) {
                    std::lock_guard<std::mutex> lock(status_mutex_);
                    status_message_ = "Event processing error: " + std::string(ex.what());
                } catch (...) {
                    std::lock_guard<std::mutex> lock(status_mutex_);
                    status_message_ = "Event processing error: unknown exception";
                }
            }

            int bytes_received = recv(socket_, buffer, sizeof(buffer) - 1, 0);
            if (bytes_received > 0) {
                buffer[bytes_received] = '\0';
                message_buffer.append(buffer, bytes_received);
            } else if (bytes_received == 0) {
                std::lock_guard<std::mutex> lock(status_mutex_);
                status_message_ = "Connection closed by master";
                connected_ = false;
                running_ = false;
                break;
            } else {
                int err = WSAGetLastError();
                if (err == WSAEWOULDBLOCK || err == WSAEINTR) {
                    Sleep(10);
                    continue;
                }
                std::lock_guard<std::mutex> lock(status_mutex_);
                status_message_ = "Receive error: " + std::to_string(err);
                connected_ = false;
                running_ = false;
                break;
            }
        }
    } catch (const std::exception& ex) {
        std::lock_guard<std::mutex> lock(status_mutex_);
        status_message_ = "TCP receive thread exception: " + std::string(ex.what());
        connected_ = false;
        running_ = false;
    } catch (...) {
        std::lock_guard<std::mutex> lock(status_mutex_);
        status_message_ = "TCP receive thread exception: unknown";
        connected_ = false;
        running_ = false;
    }

    connected_ = false;
    if (socket_ != INVALID_SOCKET) {
        closesocket(socket_);
        socket_ = INVALID_SOCKET;
    }

    {
        std::lock_guard<std::mutex> lock(status_mutex_);
        if (status_message_.empty() || status_message_ == "Connected to master") {
            status_message_ = "Connection lost";
        }
    }
}

void TcpClient::process_event(const std::string& json_event) {
    // When TCP is toggled off the socket stays connected and the master keeps
    // sending data; we just discard whatever arrives so the slave behaves as
    // if it were not listening.
    if (!BridgeServer::instance().is_tcp_connection_enabled()) {
        return;
    }

    AccountConfig config;
    if (!ConfigApi::instance().get_config(slave_account_id_, config)) {
        return;
    }

    if (!config.is_slave()) {
        return;
    }

    std::string command = SlaveConverter::convert_event_to_command(json_event, config);
    if (command.empty()) {
        return;
    }

    if (command.find("\"command_id\"") == std::string::npos) {
        static std::atomic<long> tcp_command_id{-1};
        long cmd_id = tcp_command_id.fetch_sub(1);
        size_t first_brace = command.find('{');
        if (first_brace != std::string::npos) {
            std::ostringstream ss;
            ss << "{\"command_id\":" << cmd_id << ",";
            ss << command.substr(first_brace + 1);
            command = ss.str();
        }
    }

    BridgeServer::instance().queue_command(command);
}

} 
