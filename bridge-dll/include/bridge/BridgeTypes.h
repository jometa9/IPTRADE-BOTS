#pragma once

#include <string>

namespace bridge {

struct AckPayload {
    long command_id = 0;
    int result_code = 0;
    std::string message;
    std::string data_json;
};

struct CommandEnvelope {
    long command_id = 0;
    std::string action;
    std::string payload;
};

}

