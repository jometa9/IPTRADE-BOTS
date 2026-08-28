#pragma once

#include <condition_variable>
#include <mutex>
#include <queue>
#include <string>

namespace bridge {

class CommandQueue {
public:
    void push(std::string value);
    bool pop(std::string& out);
    bool try_pop(std::string& out);
    void clear();

private:
    std::mutex mutex_;
    std::condition_variable cv_;
    std::queue<std::string> queue_;
};

}

