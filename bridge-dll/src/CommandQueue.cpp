#include "Bridge/CommandQueue.h"

namespace bridge {

void CommandQueue::push(std::string value) {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        queue_.push(std::move(value));
    }
    cv_.notify_one();
}

bool CommandQueue::pop(std::string& out) {
    std::unique_lock<std::mutex> lock(mutex_);
    cv_.wait(lock, [&]() { return !queue_.empty(); });
    out = std::move(queue_.front());
    queue_.pop();
    return true;
}

bool CommandQueue::try_pop(std::string& out) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (queue_.empty()) {
        return false;
    }
    out = std::move(queue_.front());
    queue_.pop();
    return true;
}

void CommandQueue::clear() {
    std::lock_guard<std::mutex> lock(mutex_);
    std::queue<std::string> empty;
    std::swap(queue_, empty);
}

}

