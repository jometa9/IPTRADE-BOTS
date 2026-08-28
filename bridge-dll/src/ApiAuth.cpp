#include "Bridge/ApiAuth.h"

#include <algorithm>
#include <ctime>
#include <string>

namespace bridge {

namespace {

constexpr const char kApiKeyBase[] =
    "a7f3c9e2b1d84f6a5e8c0b3d7f2a9e1c4b6d8a0f3e5c7b9d1a2e4f6c8b0d2a4";
constexpr const char kApiSecretBase[] =
    "9e5b1c7d3a6f0e2d8b4a6c0e2f4a8b0d2c6e8a0b4d6f8c0e2a4b6d8f0c2e4a6";
constexpr size_t kBaseLen = 64u;

std::string build_dynamic_key(const char* base) {
    std::time_t now = std::time(nullptr);
    std::tm tm_buf;
#ifdef _WIN32
    gmtime_s(&tm_buf, &now);
#else
    gmtime_r(&now, &tm_buf);
#endif
    int month_utc = tm_buf.tm_mon + 1;
    int part = month_utc * 2;
    char two_digits[3];
    std::snprintf(two_digits, sizeof(two_digits), "%02d", part);

    std::string result;
    result.reserve(kBaseLen + 2);
    result.append(base, 10);
    result.append(two_digits);
    result.append(base + 10, kBaseLen - 10);
    result.erase(std::remove(result.begin(), result.end(), '\0'), result.end());
    return result;
}

}

std::string get_api_key_header_value() {
    return build_dynamic_key(kApiKeyBase);
}

std::string get_api_secret_header_value() {
    return build_dynamic_key(kApiSecretBase);
}

}
