#pragma once

#include <atomic>
#include <functional>
#include <optional>
#include <string>
#include <thread>
#include <unordered_map>

#include <winsock2.h>

namespace bridge {

struct HttpRequest {
    std::string method;
    std::string path;
    std::string query;
    std::unordered_map<std::string, std::string> headers;
    std::string body;
};

struct HttpResponse {
    int status = 200;
    std::string content_type = "application/json";
    std::unordered_map<std::string, std::string> headers;
    std::string body;
};

class HttpServer {
public:
    using Handler = std::function<HttpResponse(const HttpRequest&)>;
    using StreamHandler = std::function<bool(const HttpRequest&, SOCKET)>;

    HttpServer();
    ~HttpServer();

    bool start(unsigned short min_port, unsigned short max_port);
    void stop();
    bool is_running() const { return running_; }

    unsigned short assigned_port() const { return assigned_port_; }

    void register_handler(const std::string& method,
                          const std::string& path,
                          Handler handler);
    void register_stream_handler(const std::string& method,
                                 const std::string& path,
                                 StreamHandler handler);
    static bool send_websocket_handshake(const HttpRequest& request, SOCKET client_socket);
    static bool send_websocket_text(SOCKET client_socket, const std::string& payload);

private:
    void accept_loop();
    void handle_client(SOCKET client_socket);
    std::optional<HttpRequest> parse_request(SOCKET client_socket);
    void send_response(SOCKET client_socket, const HttpResponse& response);

    std::unordered_map<std::string, Handler> handlers_;
    std::unordered_map<std::string, StreamHandler> stream_handlers_;
    std::atomic<bool> running_{false};
    unsigned short assigned_port_ = 0;

    SOCKET listen_socket_ = INVALID_SOCKET;
    std::thread accept_thread_;
};

}

