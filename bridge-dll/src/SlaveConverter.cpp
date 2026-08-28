#include "Bridge/SlaveConverter.h"
#include <algorithm>
#include <sstream>
#include <cmath>
#include <cctype>
#include <windows.h>

namespace bridge {

std::vector<std::string> SlaveConverter::extract_json_array_elements(const std::string& array_json) {
    std::vector<std::string> elements;
    size_t pos = 0;
    size_t len = array_json.size();
    while (pos < len && (array_json[pos] == ' ' || array_json[pos] == '\t' || array_json[pos] == '\n' || array_json[pos] == '\r')) {
        ++pos;
    }
    if (pos >= len || array_json[pos] != '[') {
        return elements;
    }
    ++pos;
    while (pos < len) {
        while (pos < len && (array_json[pos] == ' ' || array_json[pos] == '\t' || array_json[pos] == '\n' || array_json[pos] == '\r' || array_json[pos] == ',')) {
            ++pos;
        }
        if (pos >= len || array_json[pos] == ']') {
            break;
        }
        if (array_json[pos] != '{') {
            ++pos;
            continue;
        }
        size_t start = pos;
        int depth = 1;
        ++pos;
        while (pos < len && depth > 0) {
            char ch = array_json[pos];
            if (ch == '"') {
                ++pos;
                while (pos < len && array_json[pos] != '"') {
                    if (array_json[pos] == '\\') ++pos;
                    ++pos;
                }
                if (pos < len) ++pos;
                continue;
            }
            if (ch == '{') {
                ++depth;
            } else if (ch == '}') {
                --depth;
                if (depth == 0) {
                    ++pos;
                    elements.push_back(array_json.substr(start, pos - start));
                    break;
                }
            }
            ++pos;
        }
    }
    return elements;
}

std::string SlaveConverter::convert_event_to_command(const std::string& event_json, const AccountConfig& config) {
    if (!config.is_slave()) {
        return "";
    }
    
    std::string event_type;
    size_t event_pos = event_json.find("\"event\"");
    if (event_pos != std::string::npos) {
        size_t colon_pos = event_json.find(':', event_pos);
        if (colon_pos != std::string::npos) {
            size_t value_start = event_json.find_first_of("\"", colon_pos);
            if (value_start != std::string::npos) {
                size_t value_end = event_json.find_first_of("\"", value_start + 1);
                if (value_end != std::string::npos) {
                    event_type = event_json.substr(value_start + 1, value_end - value_start - 1);
                    std::transform(event_type.begin(), event_type.end(), event_type.begin(), ::tolower);
                }
            }
        }
    }
    if (event_type.empty()) {
        return "";
    }
    
    if (event_type == "snapshot") {
        std::string open_positions_str = extract_json_value(event_json, "open_positions");
        std::string pending_orders_str = extract_json_value(event_json, "pending_orders");
        std::vector<std::string> pos_elems = extract_json_array_elements(open_positions_str);
        std::vector<std::string> ord_elems = extract_json_array_elements(pending_orders_str);
        std::ostringstream pos_arr;
        pos_arr << "[";
        for (size_t i = 0; i < pos_elems.size(); ++i) {
            std::string converted = convert_command(pos_elems[i], config);
            if (converted.empty()) converted = pos_elems[i];
            if (i > 0) pos_arr << ",";
            pos_arr << converted;
        }
        pos_arr << "]";
        std::ostringstream ord_arr;
        ord_arr << "[";
        for (size_t i = 0; i < ord_elems.size(); ++i) {
            std::string converted = convert_command(ord_elems[i], config);
            if (converted.empty()) converted = ord_elems[i];
            if (i > 0) ord_arr << ",";
            ord_arr << converted;
        }
        ord_arr << "]";
        std::ostringstream cmd;
        cmd << "{\"action\":\"reconcile_snapshot\",\"payload\":{\"open_positions\":" << pos_arr.str() << ",\"pending_orders\":" << ord_arr.str();
        // Forward the snapshot ordering so the slave can drop stale / out-of-order snapshots.
        std::string session = extract_json_value(event_json, "session");
        std::string seq = extract_json_value(event_json, "seq");
        if (!session.empty()) cmd << ",\"session\":" << session;
        if (!seq.empty()) cmd << ",\"seq\":" << seq;
        cmd << ",\"exact_match\":" << (config.exact_match ? "true" : "false");
        cmd << "}}";
        return cmd.str();
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
    
    std::string payload = event_json;

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

    size_t account_id_pos = payload.find("\"account_id\"");
    if (account_id_pos != std::string::npos) {
        size_t colon_pos = payload.find(':', account_id_pos);
        if (colon_pos != std::string::npos) {
            size_t value_start = colon_pos + 1;
            while (value_start < payload.size() && 
                   std::isspace(static_cast<unsigned char>(payload[value_start]))) {
                ++value_start;
            }
            size_t value_end = value_start;
            while (value_end < payload.size() && 
                   payload[value_end] != ',' && 
                   payload[value_end] != '}') {
                ++value_end;
            }
            if (account_id_pos > 0 && payload[account_id_pos - 1] == ',') {
                payload = payload.substr(0, account_id_pos - 1) + payload.substr(value_end);
            } else if (value_end < payload.size() && payload[value_end] == ',') {
                payload = payload.substr(0, account_id_pos) + payload.substr(value_end + 1);
            } else {
                payload = payload.substr(0, account_id_pos) + payload.substr(value_end);
            }
        }
    }
    
    size_t platform_pos = payload.find("\"platform\"");
    if (platform_pos != std::string::npos) {
        size_t colon_pos = payload.find(':', platform_pos);
        if (colon_pos != std::string::npos) {
            size_t value_start = colon_pos + 1;
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
            if (platform_pos > 0 && payload[platform_pos - 1] == ',') {
                payload = payload.substr(0, platform_pos - 1) + payload.substr(value_end);
            } else if (value_end < payload.size() && payload[value_end] == ',') {
                payload = payload.substr(0, platform_pos) + payload.substr(value_end + 1);
            } else {
                payload = payload.substr(0, platform_pos) + payload.substr(value_end);
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

    std::string converted_payload = convert_command(payload, config);
    if (converted_payload.empty()) {
        converted_payload = payload;
    }

    std::ostringstream command;
    command << "{\"action\":\"" << action << "\",\"payload\":" << converted_payload << "}";
    std::string final_command = command.str();
    
    return final_command;
}

std::string SlaveConverter::convert_command(const std::string& command_json, const AccountConfig& config) {
    if (!config.is_slave()) {
        return command_json;
    }
    
    std::string result = command_json;
    
    bool has_payload_wrapper = (result.find("\"payload\"") != std::string::npos);
    
    std::string payload;
    if (has_payload_wrapper) {
        payload = extract_json_value(result, "payload");
        if (payload.length() >= 2 && payload.front() == '"' && payload.back() == '"') {
            payload = payload.substr(1, payload.length() - 2);
        }
        if (payload.empty() || payload == "null") {
            return command_json;
        }
    } else {
        payload = result;
    }
    
    
    std::string master_symbol = extract_json_value(payload, "symbol");
    if (!master_symbol.empty()) {
        std::string slave_symbol = convert_symbol(master_symbol, config);
        if (!slave_symbol.empty()) {
            if (payload.find("\"symbol\"") != std::string::npos) {
                payload = modify_json_value(payload, "symbol", slave_symbol);
            } else {
                size_t first_brace = payload.find('{');
                if (first_brace != std::string::npos) {
                    payload.insert(first_brace + 1, "\"symbol\":\"" + slave_symbol + "\",");
                }
            }
        }
    }
    
    
    std::string volume_str = extract_json_value(payload, "volume");
    if (!volume_str.empty()) {
        try {
            double master_volume = std::stod(volume_str);
            double slave_volume = convert_volume(master_volume, config);
            if (slave_volume > 0 && std::abs(slave_volume - master_volume) > 0.00001) {
                payload = modify_json_double(payload, "volume", slave_volume);
            }
        } catch (...) {
            
        }
    }
    
    
    if (config.reverse_trading) {
        
        std::string side = extract_json_value(payload, "side");
        if (!side.empty()) {
            std::string reversed_side = reverse_side(side);
            if (!reversed_side.empty()) {
                payload = modify_json_value(payload, "side", reversed_side);
            }
        }
        
        
        std::string order_type = extract_json_value(payload, "type");
        if (!order_type.empty() && (order_type == "limit" || order_type == "stop")) {
            std::string reversed_type = reverse_order_type(order_type);
            if (!reversed_type.empty()) {
                payload = modify_json_value(payload, "type", reversed_type);
            }
        }
        
        
        
        
        bool has_sl_key = (payload.find("\"sl\"") != std::string::npos);
        bool has_tp_key = (payload.find("\"tp\"") != std::string::npos);
        if (has_sl_key || has_tp_key) {
            std::string sl_str = extract_json_value(payload, "sl");
            std::string tp_str = extract_json_value(payload, "tp");

            if (has_tp_key && !tp_str.empty()) {
                payload = upsert_json_raw_value(payload, "sl", tp_str);
            }
            if (has_sl_key && !sl_str.empty()) {
                payload = upsert_json_raw_value(payload, "tp", sl_str);
            }
        }
    }
    
    
    if (has_payload_wrapper) {
        std::ostringstream ss;
        size_t payload_start = result.find("\"payload\"");
        size_t payload_colon = result.find(':', payload_start);
        if (payload_colon != std::string::npos) {
            ss << result.substr(0, payload_colon + 1);
            
            size_t after_colon = payload_colon + 1;
            while (after_colon < result.size() && std::isspace(static_cast<unsigned char>(result[after_colon]))) {
                after_colon++;
            }
            ss << payload;
            
            size_t payload_end = result.find_first_of(",}", after_colon);
            if (payload_end != std::string::npos) {
                ss << result.substr(payload_end);
            } else {
                ss << "}";
            }
            std::string final_result = ss.str();
            
            return final_result;
        }
    }
    
    return payload;
}

static std::string trim_whitespace(const std::string& s) {
    size_t start = 0;
    while (start < s.size() && std::isspace(static_cast<unsigned char>(s[start]))) ++start;
    if (start >= s.size()) return "";
    size_t end = s.size();
    while (end > start && std::isspace(static_cast<unsigned char>(s[end - 1]))) --end;
    return s.substr(start, end - start);
}

std::string SlaveConverter::convert_symbol(const std::string& master_symbol, const AccountConfig& config) {
    if (!config.is_slave() || master_symbol.empty()) {
        return master_symbol;
    }
    
    std::string master_trimmed = trim_whitespace(master_symbol);
    if (master_trimmed.empty()) return master_symbol;
    std::string result = master_trimmed;

    
    
    for (const auto& translation : config.symbol_translations) {
        size_t colon_pos = translation.find(':');
        if (colon_pos != std::string::npos) {
            std::string source = trim_whitespace(translation.substr(0, colon_pos));
            std::string target = trim_whitespace(translation.substr(colon_pos + 1));
            if (!source.empty() && source == master_trimmed) {
                return target.empty() ? master_trimmed : target;
            }
        }
    }

    
    
    if (config.prefix.enabled && !config.prefix.value.empty()) {
        if (config.prefix.action == "add") {
            result = config.prefix.value + result;
        } else if (config.prefix.action == "remove") {
            if (result.find(config.prefix.value) == 0) {
                result = result.substr(config.prefix.value.length());
            }
        }
    }
    
    
    if (config.suffix.enabled && !config.suffix.value.empty()) {
        if (config.suffix.action == "add") {
            result = result + config.suffix.value;
        } else if (config.suffix.action == "remove") {
            if (result.length() >= config.suffix.value.length() &&
                result.substr(result.length() - config.suffix.value.length()) == config.suffix.value) {
                result = result.substr(0, result.length() - config.suffix.value.length());
            }
        }
    }
    
    return result;
}

double SlaveConverter::convert_volume(double master_volume, const AccountConfig& config) {
    if (!config.is_slave() || master_volume <= 0) {
        return master_volume;
    }
    
    if (config.lot_type == "fixed") {
        return config.fixed_lot > 0 ? config.fixed_lot : master_volume;
    } else if (config.lot_type == "multiplier") {
        double converted = master_volume * config.lot_multiplier;
        if (converted <= 0.0) {
            return converted;
        }

        double rounded = std::round(converted * 100000.0) / 100000.0;
        if (rounded <= 0.0) {
            rounded = 0.00001;
        }
        return rounded;
    }
    
    return master_volume;
}

std::string SlaveConverter::reverse_side(const std::string& side) {
    std::string lower_side = side;
    std::transform(lower_side.begin(), lower_side.end(), lower_side.begin(), ::tolower);
    
    if (lower_side == "buy") {
        return "sell";
    } else if (lower_side == "sell") {
        return "buy";
    }
    
    return side;
}

std::string SlaveConverter::reverse_order_type(const std::string& order_type) {
    std::string lower_type = order_type;
    std::transform(lower_type.begin(), lower_type.end(), lower_type.begin(), ::tolower);
    
    if (lower_type == "limit") {
        return "stop";
    } else if (lower_type == "stop") {
        return "limit";
    }
    
    return order_type;
}

std::string SlaveConverter::modify_json_value(const std::string& json, const std::string& key, const std::string& new_value) {
    std::string needle = "\"" + key + "\"";
    size_t key_pos = json.find(needle);
    if (key_pos == std::string::npos) {
        return json;
    }
    
    size_t colon_pos = json.find(':', key_pos + needle.size());
    if (colon_pos == std::string::npos) {
        return json;
    }
    
    size_t value_start = colon_pos + 1;
    while (value_start < json.size() && std::isspace(static_cast<unsigned char>(json[value_start]))) {
        ++value_start;
    }
    
    if (value_start >= json.size()) {
        return json;
    }
    
    
    size_t value_end = value_start;
    if (json[value_start] == '"') {
        
        value_end = json.find('"', value_start + 1);
        if (value_end != std::string::npos) {
            value_end++;
        }
    } else {
        
        while (value_end < json.size() && 
               json[value_end] != ',' && 
               json[value_end] != '}' && 
               json[value_end] != ']' &&
               !std::isspace(static_cast<unsigned char>(json[value_end]))) {
            ++value_end;
        }
    }
    
    if (value_end == std::string::npos || value_end <= value_start) {
        return json;
    }
    
    std::ostringstream result;
    result << json.substr(0, value_start);
    result << "\"" << new_value << "\"";
    result << json.substr(value_end);
    
    return result.str();
}

std::string SlaveConverter::modify_json_double(const std::string& json, const std::string& key, double new_value) {
    std::string needle = "\"" + key + "\"";
    size_t key_pos = json.find(needle);
    if (key_pos == std::string::npos) {
        return json;
    }
    
    size_t colon_pos = json.find(':', key_pos + needle.size());
    if (colon_pos == std::string::npos) {
        return json;
    }
    
    size_t value_start = colon_pos + 1;
    while (value_start < json.size() && std::isspace(static_cast<unsigned char>(json[value_start]))) {
        ++value_start;
    }
    
    if (value_start >= json.size()) {
        return json;
    }
    
    
    size_t value_end = value_start;
    while (value_end < json.size() && 
           json[value_end] != ',' && 
           json[value_end] != '}' && 
           json[value_end] != ']' &&
           !std::isspace(static_cast<unsigned char>(json[value_end]))) {
        ++value_end;
    }
    
    if (value_end == std::string::npos || value_end <= value_start) {
        return json;
    }
    
    std::ostringstream result;
    result << json.substr(0, value_start);
    result.precision(5);
    result << std::fixed << new_value;
    result << json.substr(value_end);
    
    return result.str();
}

std::string SlaveConverter::upsert_json_raw_value(const std::string& json, const std::string& key, const std::string& raw_value) {
    if (raw_value.empty()) {
        return json;
    }

    std::string needle = "\"" + key + "\"";
    size_t key_pos = json.find(needle);
    if (key_pos != std::string::npos) {
        size_t colon_pos = json.find(':', key_pos + needle.size());
        if (colon_pos == std::string::npos) {
            return json;
        }

        size_t value_start = colon_pos + 1;
        while (value_start < json.size() && std::isspace(static_cast<unsigned char>(json[value_start]))) {
            ++value_start;
        }
        if (value_start >= json.size()) {
            return json;
        }

        size_t value_end = value_start;
        if (json[value_start] == '"') {
            value_end = json.find('"', value_start + 1);
            if (value_end == std::string::npos) {
                return json;
            }
            ++value_end;
        } else if (json[value_start] == '{' || json[value_start] == '[') {
            char open_char = json[value_start];
            char close_char = (open_char == '{') ? '}' : ']';
            int depth = 1;
            value_end = value_start + 1;
            while (value_end < json.size() && depth > 0) {
                if (json[value_end] == '"') {
                    ++value_end;
                    while (value_end < json.size() && json[value_end] != '"') {
                        if (json[value_end] == '\\') {
                            ++value_end;
                        }
                        ++value_end;
                    }
                } else if (json[value_end] == open_char) {
                    ++depth;
                } else if (json[value_end] == close_char) {
                    --depth;
                }
                ++value_end;
            }
            if (depth > 0) {
                return json;
            }
        } else {
            while (value_end < json.size() &&
                   json[value_end] != ',' &&
                   json[value_end] != '}' &&
                   json[value_end] != ']' &&
                   !std::isspace(static_cast<unsigned char>(json[value_end]))) {
                ++value_end;
            }
        }

        std::ostringstream result;
        result << json.substr(0, value_start);
        result << raw_value;
        result << json.substr(value_end);
        return result.str();
    }

    size_t first_brace = json.find('{');
    size_t last_brace = json.find_last_of('}');
    if (first_brace == std::string::npos || last_brace == std::string::npos || first_brace >= last_brace) {
        return json;
    }

    std::ostringstream result;
    result << json.substr(0, first_brace + 1);
    size_t insert_pos = first_brace + 1;
    while (insert_pos < last_brace && std::isspace(static_cast<unsigned char>(json[insert_pos]))) {
        ++insert_pos;
    }
    bool has_existing_fields = (insert_pos < last_brace && json[insert_pos] != '}');
    if (has_existing_fields) {
        result << "\"" << key << "\":" << raw_value << ",";
        result << json.substr(first_brace + 1);
    } else {
        result << "\"" << key << "\":" << raw_value;
        result << json.substr(last_brace);
    }

    return result.str();
}

std::string SlaveConverter::extract_json_value(const std::string& json, const std::string& key) {
    std::string needle = "\"" + key + "\"";
    size_t key_pos = json.find(needle);
    if (key_pos == std::string::npos) {
        return "";
    }
    
    size_t colon_pos = json.find(':', key_pos + needle.size());
    if (colon_pos == std::string::npos) {
        return "";
    }
    
    size_t value_start = colon_pos + 1;
    while (value_start < json.size() && std::isspace(static_cast<unsigned char>(json[value_start]))) {
        ++value_start;
    }
    
    if (value_start >= json.size()) {
        return "";
    }
    
    size_t value_end;
    if (json[value_start] == '"') {
        
        value_end = json.find('"', value_start + 1);
        if (value_end == std::string::npos) {
            return "";
        }
        return json.substr(value_start + 1, value_end - value_start - 1);
    } else if (json[value_start] == '{' || json[value_start] == '[') {
        
        char open_char = json[value_start];
        char close_char = (open_char == '{') ? '}' : ']';
        int depth = 1;
        value_end = value_start + 1;
        while (value_end < json.size() && depth > 0) {
            if (json[value_end] == open_char) {
                depth++;
            } else if (json[value_end] == close_char) {
                depth--;
            } else if (json[value_end] == '"') {
                
                size_t string_end = json.find('"', value_end + 1);
                if (string_end != std::string::npos) {
                    value_end = string_end;
                }
            }
            if (depth > 0) {
                value_end++;
            }
        }
        if (depth == 0 && value_end < json.size()) {
            value_end++;
            return json.substr(value_start, value_end - value_start);
        }
        return "";
    } else {
        
        value_end = value_start;
        while (value_end < json.size() && 
               json[value_end] != ',' && 
               json[value_end] != '}' && 
               json[value_end] != ']' &&
               !std::isspace(static_cast<unsigned char>(json[value_end]))) {
            ++value_end;
        }
        if (value_end <= value_start) {
            return "";
        }
        std::string result = json.substr(value_start, value_end - value_start);
        
        size_t first = result.find_first_not_of(" \t\n\r");
        if (first == std::string::npos) return "";
        size_t last = result.find_last_not_of(" \t\n\r");
        return result.substr(first, (last - first + 1));
    }
}

}
