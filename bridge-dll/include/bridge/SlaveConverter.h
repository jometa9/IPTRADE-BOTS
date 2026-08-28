#pragma once

#include <string>
#include <vector>
#include "AccountConfig.h"

namespace bridge {

class SlaveConverter {
public:
    static std::string convert_command(const std::string& command_json, const AccountConfig& config);
    static std::string convert_event_to_command(const std::string& event_json, const AccountConfig& config);
    static std::string convert_symbol(const std::string& master_symbol, const AccountConfig& config);
    static double convert_volume(double master_volume, const AccountConfig& config);
    static std::string reverse_side(const std::string& side);
    static std::string reverse_order_type(const std::string& order_type);

private:
    static std::string modify_json_value(const std::string& json, const std::string& key, const std::string& new_value);
    static std::string modify_json_double(const std::string& json, const std::string& key, double new_value);
    static std::string upsert_json_raw_value(const std::string& json, const std::string& key, const std::string& raw_value);
    static std::string extract_json_value(const std::string& json, const std::string& key);
    static std::vector<std::string> extract_json_array_elements(const std::string& array_json);
};

}
