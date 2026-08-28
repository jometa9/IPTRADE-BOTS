#pragma once

#include <atomic>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace bridge {

class LocalEventPoster {
public:
    LocalEventPoster();
    ~LocalEventPoster();

    void start(const std::string& external_url);
    void stop();
    bool enqueue(std::string json_payload);
    bool send_now(const std::string& json_payload);
    bool is_running() const { return running_; }

private:
    void send_async(const std::string& payload);
    bool send_payload(const std::string& payload);

    std::string external_url_;

    std::mutex threads_mutex_;
    std::atomic<int> active_threads_count_{0};
    std::atomic<bool> running_{false};
    static constexpr int MAX_CONCURRENT_THREADS = 20;
};

}

