#include "Bridge/HttpServer.h"
#include "Bridge/Encryption.h"

#include <winsock2.h>
#include <ws2tcpip.h>

#include <chrono>
#include <thread>
#include <sstream>
#include <fstream>
#include <vector>
#include <windows.h>
#include <shlwapi.h>
#include <bcrypt.h>

#pragma comment(lib, "Ws2_32.lib")
#pragma comment(lib, "shlwapi.lib")
#pragma comment(lib, "Bcrypt.lib")

namespace bridge {

namespace {

constexpr size_t kMaxRequestSize = 1 * 1024 * 1024;

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

bool read_saved_port(const char* filename, unsigned short& port_out) {
    std::string file_path = get_port_file_path(filename);
    std::ifstream file(file_path);
    if (!file.is_open()) {
        return false;
    }
    
    unsigned short port;
    if (file >> port && port > 0 && port <= 65535) {
        port_out = port;
        file.close();
        return true;
    }
    
    file.close();
    return false;
}

bool save_port(const char* filename, unsigned short port) {
    std::string file_path = get_port_file_path(filename);
    std::ofstream file(file_path, std::ios::out | std::ios::trunc);
    if (!file.is_open()) {
        return false;
    }
    
    file << port;
    file.close();
    return true;
}

bool is_port_available(unsigned short port) {
    SOCKET test_socket = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (test_socket == INVALID_SOCKET) {
        return false;
    }
    
    u_long mode = 1;
    ioctlsocket(test_socket, FIONBIO, &mode);
    
    sockaddr_in service {};
    service.sin_family = AF_INET;
    service.sin_addr.s_addr = inet_addr("127.0.0.1");
    service.sin_port = htons(port);
    
    bool available = (bind(test_socket, reinterpret_cast<SOCKADDR*>(&service), sizeof(service)) == 0);
    
    if (available) {
        closesocket(test_socket);
    } else {
        closesocket(test_socket);
    }
    
    return available;
}

std::string normalize_path(std::string path) {

    for (auto& ch : path) {
        ch = static_cast<char>(::tolower(static_cast<unsigned char>(ch)));
    }

    if (path.size() > 1 && path.back() == '/') {
        path.pop_back();
    }
    return path;
}

std::string normalize_method(std::string method) {

    for (auto& ch : method) {
        ch = static_cast<char>(::toupper(static_cast<unsigned char>(ch)));
    }
    return method;
}

std::string make_handler_key(const std::string& method, const std::string& path) {
    return normalize_method(method) + " " + normalize_path(path);
}

std::string to_lower(std::string value) {
    for (auto& ch : value) {
        ch = static_cast<char>(::tolower(static_cast<unsigned char>(ch)));
    }
    return value;
}

std::string trim_copy(const std::string& value) {
    size_t start = value.find_first_not_of(" \t\r\n");
    if (start == std::string::npos) {
        return "";
    }
    size_t end = value.find_last_not_of(" \t\r\n");
    return value.substr(start, end - start + 1);
}

std::string base64_encode_bytes(const unsigned char* data, size_t size) {
    static const char* chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    std::string result;
    result.reserve(((size + 2) / 3) * 4);
    for (size_t i = 0; i < size; i += 3) {
        unsigned int n = static_cast<unsigned int>(data[i]) << 16;
        if (i + 1 < size) n |= static_cast<unsigned int>(data[i + 1]) << 8;
        if (i + 2 < size) n |= static_cast<unsigned int>(data[i + 2]);
        result.push_back(chars[(n >> 18) & 0x3F]);
        result.push_back(chars[(n >> 12) & 0x3F]);
        result.push_back((i + 1 < size) ? chars[(n >> 6) & 0x3F] : '=');
        result.push_back((i + 2 < size) ? chars[n & 0x3F] : '=');
    }
    return result;
}

std::string websocket_accept_value(const std::string& client_key) {
    static const char kWebsocketMagic[] = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    std::string source = trim_copy(client_key) + kWebsocketMagic;

    BCRYPT_ALG_HANDLE alg = nullptr;
    BCRYPT_HASH_HANDLE hash_handle = nullptr;
    DWORD object_len = 0;
    DWORD hash_len = 0;
    DWORD result = 0;
    NTSTATUS status = BCryptOpenAlgorithmProvider(&alg, BCRYPT_SHA1_ALGORITHM, nullptr, 0);
    if (!BCRYPT_SUCCESS(status)) {
        return "";
    }

    status = BCryptGetProperty(alg, BCRYPT_OBJECT_LENGTH, reinterpret_cast<PUCHAR>(&object_len), sizeof(object_len), &result, 0);
    if (!BCRYPT_SUCCESS(status) || object_len == 0) {
        BCryptCloseAlgorithmProvider(alg, 0);
        return "";
    }
    status = BCryptGetProperty(alg, BCRYPT_HASH_LENGTH, reinterpret_cast<PUCHAR>(&hash_len), sizeof(hash_len), &result, 0);
    if (!BCRYPT_SUCCESS(status) || hash_len == 0) {
        BCryptCloseAlgorithmProvider(alg, 0);
        return "";
    }

    std::vector<unsigned char> hash_object(object_len);
    std::vector<unsigned char> hash(hash_len);
    status = BCryptCreateHash(alg, &hash_handle, hash_object.data(), object_len, nullptr, 0, 0);
    if (!BCRYPT_SUCCESS(status)) {
        BCryptCloseAlgorithmProvider(alg, 0);
        return "";
    }
    status = BCryptHashData(hash_handle, reinterpret_cast<PUCHAR>(const_cast<char*>(source.data())), static_cast<ULONG>(source.size()), 0);
    if (BCRYPT_SUCCESS(status)) {
        status = BCryptFinishHash(hash_handle, hash.data(), static_cast<ULONG>(hash.size()), 0);
    }
    BCryptDestroyHash(hash_handle);
    BCryptCloseAlgorithmProvider(alg, 0);
    if (!BCRYPT_SUCCESS(status)) {
        return "";
    }
    return base64_encode_bytes(hash.data(), hash.size());
}

bool send_all_bytes(SOCKET socket, const char* data, size_t len) {
    size_t sent_total = 0;
    while (sent_total < len) {
        int sent = send(socket, data + sent_total, static_cast<int>(len - sent_total), 0);
        if (sent <= 0) {
            return false;
        }
        sent_total += static_cast<size_t>(sent);
    }
    return true;
}

bool send_websocket_text_frame(SOCKET socket, const std::string& payload) {
    std::string frame;
    frame.reserve(payload.size() + 16);
    frame.push_back(static_cast<char>(0x81));
    const size_t payload_size = payload.size();
    if (payload_size <= 125) {
        frame.push_back(static_cast<char>(payload_size));
    } else if (payload_size <= 65535) {
        frame.push_back(static_cast<char>(126));
        frame.push_back(static_cast<char>((payload_size >> 8) & 0xFF));
        frame.push_back(static_cast<char>(payload_size & 0xFF));
    } else {
        frame.push_back(static_cast<char>(127));
        for (int shift = 56; shift >= 0; shift -= 8) {
            frame.push_back(static_cast<char>((payload_size >> shift) & 0xFF));
        }
    }
    frame.append(payload);
    return send_all_bytes(socket, frame.data(), frame.size());
}

}

HttpServer::HttpServer() {
    WSADATA wsaData;
    WSAStartup(MAKEWORD(2, 2), &wsaData);
}

HttpServer::~HttpServer() {
    stop();
    WSACleanup();
}

bool HttpServer::start(unsigned short min_port, unsigned short max_port) {
    if (running_) {
        return true;
    }

    unsigned short saved_port = 0;
    if (read_saved_port("http_port.txt", saved_port)) {
        if (saved_port >= min_port && saved_port <= max_port) {
            if (is_port_available(saved_port)) {
                SOCKET candidate = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
                if (candidate != INVALID_SOCKET) {
                    u_long mode = 1;
                    ioctlsocket(candidate, FIONBIO, &mode);

                    sockaddr_in service {};
                    service.sin_family = AF_INET;
                    service.sin_addr.s_addr = inet_addr("127.0.0.1");
                    service.sin_port = htons(saved_port);

                    if (bind(candidate, reinterpret_cast<SOCKADDR*>(&service), sizeof(service)) == 0) {
                        if (listen(candidate, SOMAXCONN) == 0) {
                            listen_socket_ = candidate;
                            assigned_port_ = saved_port;
                            running_ = true;
                            accept_thread_ = std::thread(&HttpServer::accept_loop, this);
                            return true;
                        }
                    }
                    closesocket(candidate);
                }
            }
        }
    }

    for (unsigned short port = min_port; port <= max_port; ++port) {
        SOCKET candidate = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (candidate == INVALID_SOCKET) {
            continue;
        }

        u_long mode = 1;
        ioctlsocket(candidate, FIONBIO, &mode);

        sockaddr_in service {};
        service.sin_family = AF_INET;
        service.sin_addr.s_addr = inet_addr("127.0.0.1");
        service.sin_port = htons(port);

        if (bind(candidate, reinterpret_cast<SOCKADDR*>(&service), sizeof(service)) == SOCKET_ERROR) {
            closesocket(candidate);
            continue;
        }

        if (listen(candidate, SOMAXCONN) == SOCKET_ERROR) {
            closesocket(candidate);
            continue;
        }

        listen_socket_ = candidate;
        assigned_port_ = port;
        running_ = true;
        accept_thread_ = std::thread(&HttpServer::accept_loop, this);

        save_port("http_port.txt", port);
        
        return true;
    }

    return false;
}

void HttpServer::stop() {
    running_ = false;

    if (listen_socket_ != INVALID_SOCKET) {
        closesocket(listen_socket_);
        listen_socket_ = INVALID_SOCKET;
    }

    if (accept_thread_.joinable()) {
        auto start = std::chrono::steady_clock::now();
        while (accept_thread_.joinable()) {
            std::this_thread::sleep_for(std::chrono::milliseconds(50));
            auto elapsed = std::chrono::steady_clock::now() - start;
            if (elapsed > std::chrono::seconds(2)) {
                accept_thread_.detach();
                break;
            }
        }
        if (accept_thread_.joinable()) {
            accept_thread_.join();
        }
    }
}

void HttpServer::register_handler(const std::string& method,
                                  const std::string& path,
                                  Handler handler) {

    std::string norm_method = normalize_method(method);
    std::string norm_path = normalize_path(path);
    handlers_[make_handler_key(norm_method, norm_path)] = std::move(handler);
}

void HttpServer::register_stream_handler(const std::string& method,
                                         const std::string& path,
                                         StreamHandler handler) {
    std::string norm_method = normalize_method(method);
    std::string norm_path = normalize_path(path);
    stream_handlers_[make_handler_key(norm_method, norm_path)] = std::move(handler);
}

void HttpServer::accept_loop() {
    while (running_) {
        fd_set read_set;
        FD_ZERO(&read_set);
        FD_SET(listen_socket_, &read_set);

        timeval timeout {};
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

        std::thread(&HttpServer::handle_client, this, client_socket).detach();
    }
}

void HttpServer::handle_client(SOCKET client_socket) {
    auto request = parse_request(client_socket);
    if (!request.has_value()) {
        closesocket(client_socket);
        return;
    }

    std::string norm_path = normalize_path(request->path);
    std::string norm_method = normalize_method(request->method);
    std::string key = make_handler_key(norm_method, norm_path);

    auto stream_it = stream_handlers_.find(key);
    if (stream_it == stream_handlers_.end() && norm_path.find("/api/accounts/") == 0) {
        std::string prefix_key = make_handler_key(norm_method, "/api/accounts");
        stream_it = stream_handlers_.find(prefix_key);
    }
    if (stream_it == stream_handlers_.end() && norm_path.find("/api/trade/") == 0) {
        std::string prefix_key = make_handler_key(norm_method, "/api/accounts");
        stream_it = stream_handlers_.find(prefix_key);
    }

    if (stream_it != stream_handlers_.end()) {
        bool handled = stream_it->second(*request, client_socket);
        if (!handled) {
            closesocket(client_socket);
        }
        return;
    }

    auto it = handlers_.find(key);
    
    if (it == handlers_.end() && norm_path.find("/api/accounts/") == 0) {
        std::string prefix_key = make_handler_key(norm_method, "/api/accounts");
        it = handlers_.find(prefix_key);
    }
    if (it == handlers_.end() && norm_path.find("/api/trade/") == 0) {
        std::string prefix_key = make_handler_key(norm_method, "/api/accounts");
        it = handlers_.find(prefix_key);
    }
    
    HttpResponse response;
    if (it == handlers_.end()) {
        response.status = 404;
        response.body = R"({"success":false,"error":{"code":"not_found","message":"Route not found"},"data":null})";
    } else {
        response = it->second(*request);
    }

    send_response(client_socket, response);
    closesocket(client_socket);
}

std::optional<HttpRequest> HttpServer::parse_request(SOCKET client_socket) {
    std::string buffer;
    buffer.reserve(4096);
    char chunk[2048];
    int received = 0;

    auto wait_for_data = [&]() -> bool {
        fd_set read_set;
        FD_ZERO(&read_set);
        FD_SET(client_socket, &read_set);
        timeval timeout {};
        timeout.tv_sec = 5;
        timeout.tv_usec = 0;

        return select(0, &read_set, nullptr, nullptr, &timeout) > 0;
    };

    while (wait_for_data()) {
        received = recv(client_socket, chunk, sizeof(chunk), 0);
        if (received <= 0) {
            break;
        }
        buffer.append(chunk, received);
        if (buffer.size() > kMaxRequestSize) {
            return std::nullopt;
        }
        auto header_end = buffer.find("\r\n\r\n");
        if (header_end != std::string::npos) {
            size_t total_needed = header_end + 4;
            std::string headers_part = buffer.substr(0, header_end + 2);
            std::string remainder = buffer.substr(header_end + 4);

            size_t content_length = 0;
            std::istringstream header_stream(headers_part);
            std::string line;
            std::getline(header_stream, line);
            while (std::getline(header_stream, line)) {
                if (line.size() && line.back() == '\r') {
                    line.pop_back();
                }
                auto colon = line.find(':');
                if (colon == std::string::npos) continue;
                std::string key = to_lower(line.substr(0, colon));
                std::string value = line.substr(colon + 1);
                if (!value.empty() && value[0] == ' ') value.erase(0, 1);
                if (key == "content-length") {
                    try {
                        content_length = static_cast<size_t>(std::stoul(value));
                    } catch (...) {
                        content_length = 0;
                    }
                }
            }

            while (remainder.size() < content_length && wait_for_data()) {
                received = recv(client_socket, chunk, sizeof(chunk), 0);
                if (received <= 0) break;
                remainder.append(chunk, received);
                if (remainder.size() > kMaxRequestSize) return std::nullopt;
            }

            buffer = buffer.substr(0, header_end + 4) + remainder;
            break;
        }
    }

    auto header_end = buffer.find("\r\n\r\n");
    if (header_end == std::string::npos) {
        return std::nullopt;
    }

    std::string header_text = buffer.substr(0, header_end);
    std::string body = buffer.substr(header_end + 4);

    std::istringstream header_stream(header_text);
    std::string request_line;
    std::getline(header_stream, request_line);
    if (!request_line.empty() && request_line.back() == '\r') request_line.pop_back();

    HttpRequest request;
    size_t first_space = request_line.find(' ');
    if (first_space == std::string::npos) {
        request.path.clear();
        request.query.clear();
        return request;
    }
    request.method = request_line.substr(0, first_space);
    size_t start_path = request_line.find_first_not_of(' ', first_space);
    size_t second_space = (start_path != std::string::npos) ? request_line.find(' ', start_path) : std::string::npos;
    std::string full_path = (start_path != std::string::npos && second_space != std::string::npos)
        ? request_line.substr(start_path, second_space - start_path)
        : (start_path != std::string::npos ? request_line.substr(start_path) : "");

    auto query_pos = full_path.find('?');
    if (query_pos != std::string::npos) {
        request.path = full_path.substr(0, query_pos);
        request.query = full_path.substr(query_pos + 1);
    } else {
        request.path = full_path;
        request.query.clear();
    }

    std::string header_line;
    while (std::getline(header_stream, header_line)) {
        if (!header_line.empty() && header_line.back() == '\r') {
            header_line.pop_back();
        }
        if (header_line.empty()) continue;
        auto colon = header_line.find(':');
        if (colon == std::string::npos) continue;
        std::string key = header_line.substr(0, colon);
        std::string value = header_line.substr(colon + 1);
        if (!value.empty() && value[0] == ' ') value.erase(0, 1);
        request.headers[to_lower(key)] = value;
    }

    request.body = std::move(body);

    if (Encryption::is_enabled() && !request.body.empty()) {
        request.body = Encryption::decrypt(request.body);
    }

    return request;
}

void HttpServer::send_response(SOCKET client_socket, const HttpResponse& response) {

    std::string response_body = response.body;

    std::ostringstream builder;
    builder << "HTTP/1.1 " << response.status << " ";
    builder << (response.status == 200 ? "OK" : "ERROR") << "\r\n";
    builder << "Content-Type: " << response.content_type << "\r\n";
    builder << "Content-Length: " << response_body.size() << "\r\n";
    builder << "Connection: close\r\n";
    for (const auto& [header, value] : response.headers) {
        builder << header << ": " << value << "\r\n";
    }
    builder << "\r\n";
    builder << response_body;

    std::string payload = builder.str();
    send_all_bytes(client_socket, payload.c_str(), payload.size());
}

bool HttpServer::send_websocket_handshake(const HttpRequest& request, SOCKET client_socket) {
    auto key_it = request.headers.find("sec-websocket-key");
    if (key_it == request.headers.end()) {
        return false;
    }

    auto upgrade_it = request.headers.find("upgrade");
    auto connection_it = request.headers.find("connection");
    std::string upgrade = (upgrade_it != request.headers.end()) ? to_lower(trim_copy(upgrade_it->second)) : "";
    std::string connection = (connection_it != request.headers.end()) ? to_lower(trim_copy(connection_it->second)) : "";
    if (upgrade != "websocket" || connection.find("upgrade") == std::string::npos) {
        return false;
    }

    std::string accept = websocket_accept_value(key_it->second);
    if (accept.empty()) {
        return false;
    }

    std::ostringstream handshake;
    handshake << "HTTP/1.1 101 Switching Protocols\r\n";
    handshake << "Upgrade: websocket\r\n";
    handshake << "Connection: Upgrade\r\n";
    handshake << "Sec-WebSocket-Accept: " << accept << "\r\n";
    handshake << "\r\n";
    std::string payload = handshake.str();
    return send_all_bytes(client_socket, payload.data(), payload.size());
}

bool HttpServer::send_websocket_text(SOCKET client_socket, const std::string& payload) {
    return send_websocket_text_frame(client_socket, payload);
}

}

