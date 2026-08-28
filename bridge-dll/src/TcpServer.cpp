#include "Bridge/TcpServer.h"
#include "Bridge/BridgeServer.h"
#include "Bridge/ConfigApi.h"
#include "Bridge/SlaveConverter.h"
#include <sstream>
#include <algorithm>
#include <random>
#include <memory>
#include <atomic>
#include <chrono>
#include <thread>
#include <string>
#include <fstream>
#include <mutex>
#include <windows.h>
#include <shlwapi.h>

#pragma comment(lib, "shlwapi.lib")

namespace {
    std::string get_port_file_path(const char* filename) {
        char dll_path[MAX_PATH];
        HMODULE hModule = GetModuleHandleA("copybridge.dll");
        if (hModule == NULL) {
            hModule = GetModuleHandleA(NULL);
        }
        
        if (hModule != NULL && GetModuleFileNameA(hModule, dll_path, MAX_PATH) > 0) {
            PathRemoveFileSpecA(dll_path);
            return std::string(dll_path) + "\\" + filename;
        }

        char current_dir[MAX_PATH];
        if (GetCurrentDirectoryA(MAX_PATH, current_dir) > 0) {
            return std::string(current_dir) + "\\" + filename;
        }
        
        return std::string(".\\") + filename;
    }
    
    bool read_saved_port(const char* filename, int& port_out) {
        std::string file_path = get_port_file_path(filename);
        std::ifstream file(file_path);
        if (!file.is_open()) {
            return false;
        }
        
        int port;
        if (file >> port && port > 0 && port <= 65535) {
            port_out = port;
            file.close();
            return true;
        }
        
        file.close();
        return false;
    }
    
    bool save_port(const char* filename, int port) {
        std::string file_path = get_port_file_path(filename);
        std::ofstream file(file_path, std::ios::out | std::ios::trunc);
        if (!file.is_open()) {
            return false;
        }
        
        file << port;
        file.close();
        return true;
    }

    bool send_all_nonblocking(SOCKET socket, const std::string& message) {
        if (message.empty()) {
            return true;
        }

        const char* data = message.c_str();
        int total = static_cast<int>(message.size());
        int sent_total = 0;
        int wait_attempts = 0;
        const int max_wait_attempts = 10; 

        while (sent_total < total) {
            int sent = send(socket, data + sent_total, total - sent_total, 0);
            if (sent > 0) {
                sent_total += sent;
                wait_attempts = 0;
                continue;
            }

            if (sent == 0) {
                return false;
            }

            int error = WSAGetLastError();
            if (error == WSAEWOULDBLOCK) {
                fd_set write_set;
                FD_ZERO(&write_set);
                FD_SET(socket, &write_set);
                timeval timeout{};
                timeout.tv_sec = 0;
                timeout.tv_usec = 200000;

                int select_result = select(0, nullptr, &write_set, nullptr, &timeout);
                if (select_result > 0 && FD_ISSET(socket, &write_set)) {
                    continue;
                }

                wait_attempts++;
                if (wait_attempts >= max_wait_attempts) {
                    return false;
                }
                continue;
            }

            return false;
        }

        return true;
    }

    void close_socket_gracefully(SOCKET& socket_ref) {
        if (socket_ref == INVALID_SOCKET) {
            return;
        }

        shutdown(socket_ref, SD_BOTH);
        closesocket(socket_ref);
        socket_ref = INVALID_SOCKET;
    }
}

namespace bridge {

TcpServer::TcpServer() {
    WSADATA wsaData;
    WSAStartup(MAKEWORD(2, 2), &wsaData);
}

TcpServer::~TcpServer() {
    stop();
    WSACleanup();
}

std::string TcpServer::generate_session_id() const {
    static std::random_device rd;
    static std::mt19937 gen(rd());
    static std::uniform_int_distribution<> dis(0, 15);
    
    std::stringstream ss;
    for (int i = 0; i < 8; ++i) {
        ss << std::hex << dis(gen);
    }
    return ss.str();
}

int TcpServer::find_available_port(int min_port, int max_port) {
    for (int port = min_port; port <= max_port; ++port) {
        SOCKET test_socket = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (test_socket == INVALID_SOCKET) {
            continue;
        }
        
        sockaddr_in service{};
        service.sin_family = AF_INET;
        service.sin_addr.s_addr = INADDR_ANY;
        service.sin_port = htons(port);
        
        if (bind(test_socket, reinterpret_cast<SOCKADDR*>(&service), sizeof(service)) == 0) {
            closesocket(test_socket);
            return port;
        }
        
        closesocket(test_socket);
    }
    return 0;
}

bool TcpServer::start(int min_port, int max_port) {
    if (running_) {
        return true;
    }

    int saved_port = 0;
    if (read_saved_port("tcp_port.txt", saved_port)) {
        if (saved_port >= min_port && saved_port <= max_port) {
            SOCKET test_socket = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
            if (test_socket != INVALID_SOCKET) {
                sockaddr_in test_service{};
                test_service.sin_family = AF_INET;
                test_service.sin_addr.s_addr = INADDR_ANY;
                test_service.sin_port = htons(saved_port);
                
                if (bind(test_socket, reinterpret_cast<SOCKADDR*>(&test_service), sizeof(test_service)) == 0) {
                    closesocket(test_socket);

                    listen_socket_ = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
                    if (listen_socket_ != INVALID_SOCKET) {
                        u_long mode = 1;
                        ioctlsocket(listen_socket_, FIONBIO, &mode);
                        
                        sockaddr_in service{};
                        service.sin_family = AF_INET;
                        service.sin_addr.s_addr = INADDR_ANY;
                        service.sin_port = htons(saved_port);
                        
                        if (bind(listen_socket_, reinterpret_cast<SOCKADDR*>(&service), sizeof(service)) == 0) {
                            if (listen(listen_socket_, SOMAXCONN) == 0) {
                                assigned_port_ = saved_port;
                                running_ = true;
                                accept_thread_ = std::thread(&TcpServer::accept_loop, this);
                                return true;
                            }
                        }
                        closesocket(listen_socket_);
                        listen_socket_ = INVALID_SOCKET;
                    }
                } else {
                    closesocket(test_socket);
                }
            }
        }
    }

    int port = find_available_port(min_port, max_port);
    if (port == 0) {
        return false;
    }
    
    listen_socket_ = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (listen_socket_ == INVALID_SOCKET) {
        return false;
    }
    
    u_long mode = 1;
    ioctlsocket(listen_socket_, FIONBIO, &mode);
    
    sockaddr_in service{};
    service.sin_family = AF_INET;
    service.sin_addr.s_addr = INADDR_ANY;
    service.sin_port = htons(port);
    
    if (bind(listen_socket_, reinterpret_cast<SOCKADDR*>(&service), sizeof(service)) == SOCKET_ERROR) {
        closesocket(listen_socket_);
        listen_socket_ = INVALID_SOCKET;
        return false;
    }
    
    if (listen(listen_socket_, SOMAXCONN) == SOCKET_ERROR) {
        closesocket(listen_socket_);
        listen_socket_ = INVALID_SOCKET;
        return false;
    }
    
    assigned_port_ = port;
    running_ = true;
    accept_thread_ = std::thread(&TcpServer::accept_loop, this);

    save_port("tcp_port.txt", port);
    
    return true;
}

void TcpServer::stop() {
    if (!running_) {
        return;
    }
    
    running_ = false;

    {
        std::lock_guard<std::mutex> lock(sessions_mutex_);
        for (auto& pair : sessions_) {
            if (pair.second->socket != INVALID_SOCKET) {
                pair.second->connected = false;
                close_socket_gracefully(pair.second->socket);
            }
            if (pair.second->handler_thread.joinable()) {
                pair.second->handler_thread.detach();
            }
        }
        sessions_.clear();
    }

    if (listen_socket_ != INVALID_SOCKET) {
        closesocket(listen_socket_);
        listen_socket_ = INVALID_SOCKET;
    }

    if (accept_thread_.joinable()) {
        accept_thread_.detach();
    }
}

void TcpServer::accept_loop() {
    while (running_) {
        fd_set read_set;
        FD_ZERO(&read_set);
        FD_SET(listen_socket_, &read_set);
        
        timeval timeout{};
        timeout.tv_sec = 0;
        timeout.tv_usec = 200000;

        int select_result = select(0, &read_set, nullptr, nullptr, &timeout);
        if (select_result <= 0) {
            continue;
        }

        SOCKET client_socket = accept(listen_socket_, nullptr, nullptr);
        if (client_socket == INVALID_SOCKET) {
            continue;
        }

        std::thread(&TcpServer::handle_client, this, client_socket).detach();
    }
}

bool TcpServer::receive_connection_account_id(SOCKET client_socket, std::string& account_id_out) {
    std::string line;
    line.reserve(256);
    char buf[256];
    const int timeout_sec = 5;
    auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(timeout_sec);
    while (line.find('\n') == std::string::npos) {
        if (std::chrono::steady_clock::now() > deadline) {
            return false;
        }
        fd_set read_set;
        FD_ZERO(&read_set);
        FD_SET(client_socket, &read_set);
        timeval tv;
        tv.tv_sec = 1;
        tv.tv_usec = 0;
        if (select(0, &read_set, nullptr, nullptr, &tv) <= 0 || !FD_ISSET(client_socket, &read_set)) {
            continue;
        }
        int n = recv(client_socket, buf, sizeof(buf) - 1, 0);
        if (n <= 0) return false;
        buf[n] = '\0';
        line.append(buf);
    }
    size_t end = line.find('\n');
    std::string message = line.substr(0, end);
    account_id_out.clear();
    size_t account_id_pos = message.find("\"account_id\"");
    if (account_id_pos == std::string::npos) {
        account_id_pos = message.find("\"accountId\"");
    }
    if (account_id_pos != std::string::npos) {
        size_t colon_pos = message.find(':', account_id_pos);
        if (colon_pos != std::string::npos) {
            size_t value_start = message.find_first_of("\"", colon_pos);
            if (value_start != std::string::npos) {
                size_t value_end = message.find_first_of("\"", value_start + 1);
                if (value_end != std::string::npos) {
                    account_id_out = message.substr(value_start + 1, value_end - value_start - 1);
                }
            }
        }
    }
    if (account_id_out.empty()) {
        message.erase(std::remove_if(message.begin(), message.end(),
            [](char c) { return c == '\n' || c == '\r' || c == ' ' || c == '\t'; }), message.end());
        if (!message.empty()) account_id_out = message;
    }
    if (account_id_out.empty()) account_id_out = "observer";
    std::ostringstream response;
    response << "{\"status\":\"ready\",\"account_id\":\"" << account_id_out << "\"}\n";
    std::string response_str = response.str();
    return send_all_nonblocking(client_socket, response_str);
}

void TcpServer::handle_client(SOCKET client_socket) {
    std::string account_id;
    std::string session_key;
    if (!receive_connection_account_id(client_socket, account_id)) {
        close_socket_gracefully(client_socket);
        return;
    }
    
    u_long mode = 1;
    ioctlsocket(client_socket, FIONBIO, &mode);
    
    auto session = std::make_shared<TcpClientSession>();
    session->session_id = generate_session_id();
    session->account_id = account_id;
    session->socket = client_socket;
    session->connected = true;
    
    session_key = account_id + ":" + session->session_id;
    {
        std::lock_guard<std::mutex> lock(sessions_mutex_);
        sessions_[session_key] = session;
    }
    
    {
        std::lock_guard<std::mutex> lock(on_new_session_mutex_);
        if (on_new_session_callback_) {
            on_new_session_callback_(account_id);
        }
    }
    
    receive_commands_loop(client_socket, account_id);
    
    {
        std::lock_guard<std::mutex> lock(sessions_mutex_);
        if (sessions_.find(session_key) != sessions_.end()) {
            sessions_.erase(session_key);
        }
    }
    
    if (client_socket != INVALID_SOCKET) {
        close_socket_gracefully(client_socket);
    }
}

void TcpServer::receive_commands_loop(SOCKET client_socket, const std::string& account_id) {
    char buffer[8192];
    std::string message_buffer;
    
    while (running_) {
        fd_set read_set;
        FD_ZERO(&read_set);
        FD_SET(client_socket, &read_set);
        
        timeval timeout{};
        timeout.tv_sec = 0;
        timeout.tv_usec = 200000;
        
        int select_result = select(0, &read_set, nullptr, nullptr, &timeout);
        if (select_result <= 0) {
            if (!running_) break;
            continue;
        }
        
        if (!FD_ISSET(client_socket, &read_set)) {
            if (!running_) break;
            continue;
        }
        
        int bytes_received = recv(client_socket, buffer, sizeof(buffer) - 1, 0);
        
        if (bytes_received <= 0) {
            int error = WSAGetLastError();
            if (error == WSAEWOULDBLOCK) {
                if (!running_) break;
                continue;
            }
            {
                std::lock_guard<std::mutex> lock(sessions_mutex_);
                std::string prefix = account_id + ":";
                for (auto& pair : sessions_) {
                    if (pair.first.find(prefix) == 0 && pair.second->socket == client_socket) {
                        pair.second->connected = false;
                        break;
                    }
                }
            }
            break;
        }
        
        buffer[bytes_received] = '\0';
        message_buffer.append(buffer, bytes_received);
        
        size_t newline_pos;
        while ((newline_pos = message_buffer.find('\n')) != std::string::npos) {
            std::string message = message_buffer.substr(0, newline_pos);
            message_buffer = message_buffer.substr(newline_pos + 1);
            
            if (!message.empty()) {
                process_command(client_socket, account_id, message);
            }
        }
    }
}

std::string convert_event_to_command(const std::string& json_event) {
    std::string event_type;
    size_t event_pos = json_event.find("\"event\"");
    if (event_pos != std::string::npos) {
        size_t colon_pos = json_event.find(':', event_pos);
        if (colon_pos != std::string::npos) {
            size_t value_start = json_event.find_first_of("\"", colon_pos);
            if (value_start != std::string::npos) {
                size_t value_end = json_event.find_first_of("\"", value_start + 1);
                if (value_end != std::string::npos) {
                    event_type = json_event.substr(value_start + 1, value_end - value_start - 1);
                    std::transform(event_type.begin(), event_type.end(), event_type.begin(), ::tolower);
                }
            }
        }
    }
    
    if (event_type.empty()) {
        return "";
    }
    
    std::string action;
    if (event_type == "placed") {
        action = "create";
    } else if (event_type == "modified") {
        action = "modify";
    } else if (event_type == "closed") {
        action = "cancel";
    } else {
        return "";
    }
    
    std::string payload = json_event;
    
    size_t event_start = payload.find("\"event\"");
    if (event_start != std::string::npos) {
        size_t event_colon = payload.find(':', event_start);
        if (event_colon != std::string::npos) {
            size_t value_start = event_colon + 1;
            while (value_start < payload.size() && 
                   std::isspace(static_cast<unsigned char>(payload[value_start]))) {
                ++value_start;
            }
            
            size_t value_end = value_start;
            if (payload[value_start] == '"') {
                value_end = payload.find('"', value_start + 1);
                if (value_end != std::string::npos) {
                    value_end++;
                }
            } else {
                while (value_end < payload.size() && 
                       payload[value_end] != ',' && 
                       payload[value_end] != '}') {
                    ++value_end;
                }
            }
            
            if (event_start > 0 && payload[event_start - 1] == ',') {
                payload = payload.substr(0, event_start - 1) + payload.substr(value_end);
            } else if (value_end < payload.size() && payload[value_end] == ',') {
                payload = payload.substr(0, event_start) + payload.substr(value_end + 1);
            } else {
                payload = payload.substr(0, event_start) + payload.substr(value_end);
            }
        }
    }
    
    size_t double_comma;
    while ((double_comma = payload.find(",,")) != std::string::npos) {
        payload.replace(double_comma, 2, ",");
    }
    
    size_t first_brace = payload.find('{');
    if (first_brace != std::string::npos) {
        size_t after_brace = first_brace + 1;
        while (after_brace < payload.size() && 
               std::isspace(static_cast<unsigned char>(payload[after_brace]))) {
            ++after_brace;
        }
        if (after_brace < payload.size() && payload[after_brace] == ',') {
            payload = payload.substr(0, after_brace) + payload.substr(after_brace + 1);
        }
    }
    
    size_t last_brace = payload.find_last_of('}');
    if (last_brace != std::string::npos && last_brace > 0) {
        size_t before_brace = last_brace - 1;
        while (before_brace > 0 && 
               std::isspace(static_cast<unsigned char>(payload[before_brace]))) {
            --before_brace;
        }
        if (before_brace > 0 && payload[before_brace] == ',') {
            payload = payload.substr(0, before_brace) + payload.substr(before_brace + 1);
        }
    }
    
    std::ostringstream command;
    command << "{\"action\":\"" << action << "\",\"payload\":" << payload << "}";
    return command.str();
}

void TcpServer::process_command(SOCKET client_socket, const std::string& account_id, const std::string& json_command) {
    bool is_event = (json_command.find("\"event\"") != std::string::npos);
    bool is_command = (json_command.find("\"action\"") != std::string::npos);
    
    std::string final_command = json_command;
    std::string action;
    
    if (is_event && !is_command) {
        final_command = convert_event_to_command(json_command);
        if (final_command.empty()) {
            std::ostringstream response;
            response << R"({"status":"error","message":"Error"})" << "\n";
            send_response(client_socket, response.str());
            return;
        }
        
        size_t action_pos = final_command.find("\"action\"");
        if (action_pos != std::string::npos) {
            size_t colon_pos = final_command.find(':', action_pos);
            if (colon_pos != std::string::npos) {
                size_t value_start = final_command.find_first_of("\"", colon_pos);
                if (value_start != std::string::npos) {
                    size_t value_end = final_command.find_first_of("\"", value_start + 1);
                    if (value_end != std::string::npos) {
                        action = final_command.substr(value_start + 1, value_end - value_start - 1);
                        std::transform(action.begin(), action.end(), action.begin(), ::tolower);
                    }
                }
            }
        }
        
        AccountConfig config;
        if (ConfigApi::instance().get_config(account_id, config)) {
            if (config.is_slave()) {
                std::string payload;
                size_t payload_pos = final_command.find("\"payload\"");
                if (payload_pos != std::string::npos) {
                    size_t colon_pos = final_command.find(':', payload_pos);
                    if (colon_pos != std::string::npos) {
                        size_t value_start = colon_pos + 1;
                        while (value_start < final_command.size() && 
                               std::isspace(static_cast<unsigned char>(final_command[value_start]))) {
                            ++value_start;
                        }
                        size_t value_end = value_start;
                        if (final_command[value_start] == '{') {
                            int depth = 1;
                            value_end = value_start + 1;
                            while (value_end < final_command.size() && depth > 0) {
                                if (final_command[value_end] == '{') depth++;
                                else if (final_command[value_end] == '}') depth--;
                                value_end++;
                            }
                        } else if (final_command[value_start] == '"') {
                            value_end = final_command.find('"', value_start + 1);
                            if (value_end != std::string::npos) value_end++;
                        } else {
                            while (value_end < final_command.size() && 
                                   final_command[value_end] != ',' && 
                                   final_command[value_end] != '}') {
                                value_end++;
                            }
                        }
                        payload = final_command.substr(value_start, value_end - value_start);
                    }
                }
                
                if (!payload.empty()) {
                    std::string converted_payload = SlaveConverter::convert_command(payload, config);
                    if (!converted_payload.empty() && converted_payload != payload) {
                        size_t payload_start = final_command.find("\"payload\"");
                        if (payload_start != std::string::npos) {
                            size_t colon_pos = final_command.find(':', payload_start);
                            if (colon_pos != std::string::npos) {
                                size_t value_start = colon_pos + 1;
                                while (value_start < final_command.size() && 
                                       std::isspace(static_cast<unsigned char>(final_command[value_start]))) {
                                    ++value_start;
                                }
                                size_t value_end = value_start;
                                if (final_command[value_start] == '{') {
                                    int depth = 1;
                                    value_end = value_start + 1;
                                    while (value_end < final_command.size() && depth > 0) {
                                        if (final_command[value_end] == '{') depth++;
                                        else if (final_command[value_end] == '}') depth--;
                                        value_end++;
                                    }
                                } else {
                                    while (value_end < final_command.size() && 
                                           final_command[value_end] != ',' && 
                                           final_command[value_end] != '}') {
                                        value_end++;
                                    }
                                }
                                std::ostringstream ss;
                                ss << final_command.substr(0, value_start);
                                ss << converted_payload;
                                ss << final_command.substr(value_end);
                                final_command = ss.str();
                            }
                        }
                    }
                }
            }
        }
    } else if (is_command) {
        size_t action_pos = final_command.find("\"action\"");
        if (action_pos != std::string::npos) {
            size_t colon_pos = final_command.find(':', action_pos);
            if (colon_pos != std::string::npos) {
                size_t value_start = final_command.find_first_of("\"", colon_pos);
                if (value_start != std::string::npos) {
                    size_t value_end = final_command.find_first_of("\"", value_start + 1);
                    if (value_end != std::string::npos) {
                        action = final_command.substr(value_start + 1, value_end - value_start - 1);
                        std::transform(action.begin(), action.end(), action.begin(), ::tolower);
                    }
                }
            }
        }
    } else {
        std::ostringstream response;
        response << R"({"status":"error","message":"Error"})" << "\n";
        send_response(client_socket, response.str());
        return;
    }
    
    if (action == "create" || action == "modify" || action == "cancel") {
        std::string command_with_id = final_command;
        if (command_with_id.find("\"command_id\"") == std::string::npos) {
            static std::atomic<long> tcp_command_id{-1};
            long cmd_id = tcp_command_id.fetch_sub(1);
            
            size_t first_brace = command_with_id.find('{');
            if (first_brace != std::string::npos) {
                std::ostringstream ss;
                ss << "{\"command_id\":" << cmd_id << ",";
                ss << command_with_id.substr(first_brace + 1);
                command_with_id = ss.str();
            }
        }
        
        BridgeServer::instance().queue_command(command_with_id);
        
        std::ostringstream response;
        response << R"({"status":"queued","action":")" << action << R"(","account_id":")" << account_id << "\"}\n";
        send_response(client_socket, response.str());
    } else {
        std::ostringstream response;
        response << R"({"status":"error","message":"Error"})" << "\n";
        send_response(client_socket, response.str());
    }
}

void TcpServer::send_response(SOCKET client_socket, const std::string& json_response) {
    send_all_nonblocking(client_socket, json_response);
}

void TcpServer::broadcast_event(const std::string& account_id, const std::string& json_event) {
    std::lock_guard<std::mutex> lock(sessions_mutex_);
    
    std::string prefix = account_id + ":";
    std::string message = json_event + "\n";
    
    for (auto it = sessions_.begin(); it != sessions_.end();) {
        if (it->first.find(prefix) == 0 && it->second->connected) {
            SOCKET socket = it->second->socket;
            if (!send_all_nonblocking(socket, message)) {
                close_socket_gracefully(socket);
                it->second->connected = false;
                it->second->socket = INVALID_SOCKET;
                it = sessions_.erase(it);
            } else {
                ++it;
            }
        } else {
            ++it;
        }
    }
}

void TcpServer::broadcast_to_all(const std::string& json_event) {
    std::lock_guard<std::mutex> lock(sessions_mutex_);
    int connected_count = 0;
    for (const auto& p : sessions_) {
        if (p.second->connected) connected_count++;
    }
    std::string message = json_event + "\n";
    int sent_count = 0;
    for (auto it = sessions_.begin(); it != sessions_.end();) {
        if (it->second->connected) {
            SOCKET socket = it->second->socket;
            if (!send_all_nonblocking(socket, message)) {
                close_socket_gracefully(socket);
                it->second->connected = false;
                it->second->socket = INVALID_SOCKET;
                it = sessions_.erase(it);
            } else {
                sent_count++;
                ++it;
            }
        } else {
            ++it;
        }
    }
}

bool TcpServer::has_clients_for_account(const std::string& account_id) const {
    std::lock_guard<std::mutex> lock(sessions_mutex_);
    
    std::string prefix = account_id + ":";
    for (const auto& pair : sessions_) {
        if (pair.first.find(prefix) == 0 && pair.second->connected) {
            return true;
        }
    }
    
    return false;
}

void TcpServer::disconnect_clients_for_account(const std::string& account_id) {
    std::lock_guard<std::mutex> lock(sessions_mutex_);

    std::string prefix = account_id + ":";
    for (auto it = sessions_.begin(); it != sessions_.end();) {
        if (it->first.find(prefix) == 0) {
            if (it->second->socket != INVALID_SOCKET) {
                close_socket_gracefully(it->second->socket);
            }
            it->second->connected = false;
            it = sessions_.erase(it);
        } else {
            ++it;
        }
    }
}

void TcpServer::disconnect_all_clients() {
    std::lock_guard<std::mutex> lock(sessions_mutex_);
    for (auto& pair : sessions_) {
        if (pair.second->socket != INVALID_SOCKET) {
            close_socket_gracefully(pair.second->socket);
        }
        pair.second->connected = false;
    }
    sessions_.clear();
}

void TcpServer::set_on_new_session_callback(std::function<void(const std::string& account_id)> cb) {
    std::lock_guard<std::mutex> lock(on_new_session_mutex_);
    on_new_session_callback_ = std::move(cb);
}

}
