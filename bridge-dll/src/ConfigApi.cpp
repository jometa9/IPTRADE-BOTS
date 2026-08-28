#include "Bridge/ConfigApi.h"
#include "Bridge/HeartbeatService.h"
#include <algorithm>
#include <cstdio>
#include <fstream>
#include <sstream>
#include <windows.h>
#include <shlwapi.h>
#include <direct.h>

#pragma comment(lib, "shlwapi.lib")

namespace bridge {

ConfigApi& ConfigApi::instance() {
    static ConfigApi api;
    if (!api.initialized_) {
        api.load_all_configs();
        api.initialized_ = true;
    }
    return api;
}

ConfigApi::ConfigApi() : initialized_(false) {
    char dll_path[MAX_PATH];
    HMODULE hModule = GetModuleHandleA("copybridge.dll");
    if (hModule == NULL) {
        hModule = GetModuleHandleA(NULL);
    }

    if (hModule != NULL && GetModuleFileNameA(hModule, dll_path, MAX_PATH) > 0) {
        PathRemoveFileSpecA(dll_path);
        config_directory_ = std::string(dll_path) + "\\configs";
        _mkdir(config_directory_.c_str());
    } else {
        char current_dir[MAX_PATH];
        if (GetCurrentDirectoryA(MAX_PATH, current_dir) > 0) {
            config_directory_ = std::string(current_dir) + "\\configs";
        } else {
            config_directory_ = ".\\configs";
        }
        _mkdir(config_directory_.c_str());
    }
}

bool ConfigApi::get_config(const std::string& account_id, AccountConfig& config_out) const {
    std::lock_guard<std::mutex> lock(config_mutex_);
    
    auto it = configs_.find(account_id);
    if (it != configs_.end()) {
        config_out = it->second;
        return true;
    }

    std::string current_id = HeartbeatService::instance().get_account_id();
    if (account_id != current_id) {
        return false;
    }
    
    if (session_cleared_accounts_.count(account_id) != 0) {
        return false;
    }

    return false;
}

bool ConfigApi::set_config(const std::string& account_id, const AccountConfig& config) {
    std::string error_message;
    if (!validate_config(config, error_message)) {
        return false;
    }
    
    std::lock_guard<std::mutex> lock(config_mutex_);

    AccountConfig config_to_save = config;
    if (config_to_save.is_master()) {
        config_to_save.master_tcp_url.clear();
    }
    
    configs_[account_id] = config_to_save;

    save_config_to_file(account_id, config_to_save);
    
    return true;
}

bool ConfigApi::delete_config(const std::string& account_id) {
    if (account_id.empty()) return false;
    std::lock_guard<std::mutex> lock(config_mutex_);
    bool was_in_memory = configs_.erase(account_id) > 0;
    session_cleared_accounts_.erase(account_id);
    std::string file_path = get_config_file_path(account_id);
    DeleteFileA(file_path.c_str());
    return was_in_memory;
}

bool ConfigApi::validate_config(const AccountConfig& config, std::string& error_message) const {
    if (!config.is_valid()) {
        error_message = "Invalid role. Must be 'master', 'slave', or 'pending'";
        return false;
    }

    if (config.lot_type != "multiplier" && config.lot_type != "fixed") {
        error_message = "lot_type must be 'fixed' or 'multiplier'";
        return false;
    }

    if (!config.prefix.action.empty() && config.prefix.action != "add" && config.prefix.action != "remove") {
        error_message = "prefix.action must be 'add' or 'remove'";
        return false;
    }
    
    if (!config.suffix.action.empty() && config.suffix.action != "add" && config.suffix.action != "remove") {
        error_message = "suffix.action must be 'add' or 'remove'";
        return false;
    }
    
    return true;
}

bool ConfigApi::has_config(const std::string& account_id) const {
    std::lock_guard<std::mutex> lock(config_mutex_);
    return configs_.find(account_id) != configs_.end();
}

std::vector<std::string> ConfigApi::get_all_account_ids() const {
    std::lock_guard<std::mutex> lock(config_mutex_);
    std::vector<std::string> account_ids;
    account_ids.reserve(configs_.size());
    for (const auto& pair : configs_) {
        account_ids.push_back(pair.first);
    }
    return account_ids;
}

std::string ConfigApi::get_config_directory() const {
    return config_directory_;
}

std::string ConfigApi::get_config_file_path(const std::string& account_id) const {
    return config_directory_ + "\\config_" + account_id + ".json";
}

bool ConfigApi::save_config_to_file(const std::string& account_id, const AccountConfig& config) const {
    std::string file_path = get_config_file_path(account_id);
    std::ofstream file(file_path, std::ios::out | std::ios::trunc);
    if (!file.is_open()) {
        return false;
    }
    
    std::string json = config_to_json(config);
    file << json;
    file.flush();
    file.close();

    return true;
}

bool ConfigApi::load_config_from_file_impl(const std::string& account_id, AccountConfig& config_out) const {
    std::string file_path = get_config_file_path(account_id);
    std::ifstream file(file_path, std::ios::in);
    if (!file.is_open()) {
        return false;
    }
    
    std::ostringstream buffer;
    buffer << file.rdbuf();
    std::string json = buffer.str();
    file.close();
    
    if (json.empty()) {
        return false;
    }
    
    config_out = parse_config_json(json, "config file");
    return config_out.is_valid();
}

bool ConfigApi::load_config_from_file(const std::string& account_id) {
    AccountConfig config;
    if (load_config_from_file_impl(account_id, config)) {
        std::lock_guard<std::mutex> lock(config_mutex_);
        configs_[account_id] = config;
        return true;
    }
    return false;
}

void ConfigApi::clear_from_memory(const std::string& account_id) {
    if (account_id.empty()) return;
    std::lock_guard<std::mutex> lock(config_mutex_);
    configs_.erase(account_id);
    session_cleared_accounts_.insert(account_id);
}

void ConfigApi::allow_config_load(const std::string& account_id) {
    if (account_id.empty()) return;
    std::lock_guard<std::mutex> lock(config_mutex_);
    session_cleared_accounts_.erase(account_id);
}

void ConfigApi::load_all_configs() {
    std::lock_guard<std::mutex> lock(config_mutex_);
    
    std::string search_path = config_directory_ + "\\config_*.json";
    
    WIN32_FIND_DATAA find_data;
    HANDLE find_handle = FindFirstFileA(search_path.c_str(), &find_data);
    
    if (find_handle != INVALID_HANDLE_VALUE) {
        do {
            if (!(find_data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)) {
                std::string filename = find_data.cFileName;
                if (filename.length() > 11 && filename.substr(0, 7) == "config_" && filename.substr(filename.length() - 5) == ".json") {
                    std::string account_id = filename.substr(7, filename.length() - 12);
                    AccountConfig config;
                    if (load_config_from_file_impl(account_id, config)) {
                        configs_[account_id] = config;
                    }
                }
            }
        } while (FindNextFileA(find_handle, &find_data) != 0);
        
        FindClose(find_handle);
    }
}

AccountConfig ConfigApi::parse_config_json(const std::string& json, const char* source) const {
    (void)source;
    AccountConfig config;
    config.role = extract_json_string_value(json, "role");
    
    config.master_tcp_url = extract_json_string_value(json, "master_tcp_url");
    if (config.master_tcp_url.empty()) {
        config.master_tcp_url = extract_json_string_value(json, "masterTcpUrl");
    }
    
    config.lot_type = extract_json_string_value(json, "lot_type");
    if (config.lot_type.empty()) {
        config.lot_type = extract_json_string_value(json, "lotType");
    }
    if (config.lot_type.empty()) {
        config.lot_type = "multiplier";
    }
    if (config.lot_type == "fixedlot") {
        config.lot_type = "fixed";
    }
    
    std::string lot_mult_str = extract_json_section(json, "lot_multiplier");
    if (lot_mult_str.empty()) {
        lot_mult_str = extract_json_section(json, "lotMultiplier");
    }
    if (!lot_mult_str.empty()) {
        try {
            config.lot_multiplier = std::stod(lot_mult_str);
        } catch (...) {
            config.lot_multiplier = 1.0;
        }
    }
    
    std::string fixed_lot_str = extract_json_section(json, "fixed_lot");
    if (fixed_lot_str.empty()) {
        fixed_lot_str = extract_json_section(json, "fixedLot");
    }
    if (!fixed_lot_str.empty()) {
        try {
            config.fixed_lot = std::stod(fixed_lot_str);
        } catch (...) {
            config.fixed_lot = 0.0;
        }
    }
    
    std::string reverse_str = extract_json_section(json, "reverse_trading");
    if (reverse_str.empty()) {
        reverse_str = extract_json_section(json, "reverseTrading");
    }
    if (!reverse_str.empty()) {
        config.reverse_trading = (reverse_str == "true" || reverse_str == "1");
    }

    std::string exact_match_str = extract_json_section(json, "exact_match");
    if (exact_match_str.empty()) {
        exact_match_str = extract_json_section(json, "exactMatch");
    }
    if (!exact_match_str.empty()) {
        config.exact_match = (exact_match_str == "true" || exact_match_str == "1");
    }

    std::string prefix_obj = extract_json_section(json, "prefix");
    if (!prefix_obj.empty() && prefix_obj[0] == '{') {
        std::string prefix_enabled = extract_json_section(prefix_obj, "enabled");
        config.prefix.enabled = (prefix_enabled == "true" || prefix_enabled == "1");
        config.prefix.value = extract_json_string_value(prefix_obj, "value");
        config.prefix.action = extract_json_string_value(prefix_obj, "action");
    } else {
        std::string prefix_enabled = extract_json_section(json, "prefix_enabled");
        config.prefix.enabled = (prefix_enabled == "true" || prefix_enabled == "1");
        config.prefix.value = extract_json_string_value(json, "prefix_value");
        config.prefix.action = extract_json_string_value(json, "prefix_action");
    }
    if (config.prefix.action.empty()) {
        config.prefix.action = "add";
    }
    
    std::string suffix_obj = extract_json_section(json, "suffix");
    if (!suffix_obj.empty() && suffix_obj[0] == '{') {
        std::string suffix_enabled = extract_json_section(suffix_obj, "enabled");
        config.suffix.enabled = (suffix_enabled == "true" || suffix_enabled == "1");
        config.suffix.value = extract_json_string_value(suffix_obj, "value");
        config.suffix.action = extract_json_string_value(suffix_obj, "action");
    } else {
        std::string suffix_enabled = extract_json_section(json, "suffix_enabled");
        config.suffix.enabled = (suffix_enabled == "true" || suffix_enabled == "1");
        config.suffix.value = extract_json_string_value(json, "suffix_value");
        config.suffix.action = extract_json_string_value(json, "suffix_action");
    }
    if (config.suffix.action.empty()) {
        config.suffix.action = "add";
    }
    
    std::string array_str = extract_json_section(json, "symbolTranslations");
    if (array_str.empty()) {
        array_str = extract_json_section(json, "symbol_translations");
    }
    
    if (!array_str.empty() && array_str[0] == '[') {
        std::string array_content = array_str.substr(1);
        if (!array_content.empty() && array_content.back() == ']') {
            array_content.pop_back();
        }
        
        size_t pos = 0;
        while (pos < array_content.length()) {
            while (pos < array_content.length() && std::isspace(static_cast<unsigned char>(array_content[pos]))) {
                pos++;
            }
            if (pos >= array_content.length()) break;
            
            if (array_content[pos] == ',') {
                pos++;
                continue;
            }
            
            if (array_content[pos] == '"') {
                size_t start = pos + 1;
                size_t end = start;
                bool escape = false;
                
                while (end < array_content.length()) {
                    char ch = array_content[end];
                    if (escape) {
                        escape = false;
                        end++;
                        continue;
                    }
                    if (ch == '\\') {
                        escape = true;
                        end++;
                        continue;
                    }
                    if (ch == '"') {
                        std::string translation = array_content.substr(start, end - start);
                        if (!translation.empty()) {
                            config.symbol_translations.push_back(translation);
                        }
                        pos = end + 1;
                        break;
                    }
                    end++;
                }
                
                if (end >= array_content.length()) {
                    break;
                }
            } else {
                size_t next_comma = array_content.find(',', pos);
                if (next_comma != std::string::npos) {
                    pos = next_comma + 1;
                } else {
                    break;
                }
            }
        }
    }
    
    return config;
}

std::string ConfigApi::config_to_json(const AccountConfig& config) const {
    std::ostringstream ss;
    ss << "{";
    ss << "\"role\":\"" << json_escape(config.role) << "\",";
    ss << "\"master_tcp_url\":";
    if (config.master_tcp_url.empty()) {
        ss << "null";
    } else {
        ss << "\"" << json_escape(config.master_tcp_url) << "\"";
    }
    ss << ",";
    ss << "\"lot_type\":\"" << json_escape(config.lot_type) << "\",";
    ss << "\"lot_multiplier\":" << config.lot_multiplier << ",";
    ss << "\"fixed_lot\":" << config.fixed_lot << ",";
    ss << "\"reverse_trading\":" << (config.reverse_trading ? "true" : "false") << ",";
    ss << "\"exact_match\":" << (config.exact_match ? "true" : "false") << ",";
    ss << "\"prefix\":{";
    ss << "\"enabled\":" << (config.prefix.enabled ? "true" : "false") << ",";
    ss << "\"value\":";
    if (config.prefix.value.empty()) {
        ss << "null";
    } else {
        ss << "\"" << json_escape(config.prefix.value) << "\"";
    }
    ss << ",";
    ss << "\"action\":\"" << json_escape(config.prefix.action) << "\"";
    ss << "},";
    ss << "\"suffix\":{";
    ss << "\"enabled\":" << (config.suffix.enabled ? "true" : "false") << ",";
    ss << "\"value\":";
    if (config.suffix.value.empty()) {
        ss << "null";
    } else {
        ss << "\"" << json_escape(config.suffix.value) << "\"";
    }
    ss << ",";
    ss << "\"action\":\"" << json_escape(config.suffix.action) << "\"";
    ss << "},";
    ss << "\"symbol_translations\":[";
    for (size_t i = 0; i < config.symbol_translations.size(); ++i) {
        if (i > 0) ss << ",";
        ss << "\"" << json_escape(config.symbol_translations[i]) << "\"";
    }
    ss << "]";
    ss << "}";
    return ss.str();
}

std::string ConfigApi::extract_json_string_value(const std::string& json, const std::string& key) const {
    std::string search_key = "\"" + key + "\"";
    size_t key_pos = json.find(search_key);
    if (key_pos == std::string::npos) {
        return "";
    }
    size_t colon_pos = json.find(':', key_pos + search_key.size());
    if (colon_pos == std::string::npos) {
        return "";
    }
    size_t value_pos = colon_pos + 1;
    while (value_pos < json.size() && std::isspace(static_cast<unsigned char>(json[value_pos]))) {
        ++value_pos;
    }
    if (value_pos >= json.size()) {
        return "";
    }
    if (json[value_pos] == '"') {
        size_t start = value_pos + 1;
        size_t end = start;
        bool escape = false;
        while (end < json.size()) {
            char ch = json[end];
            if (escape) {
                escape = false;
                ++end;
                continue;
            }
            if (ch == '\\') {
                escape = true;
                ++end;
                continue;
            }
            if (ch == '"') {
                return json.substr(start, end - start);
            }
            ++end;
        }
        return "";
    }
    if (value_pos + 4 <= json.size() && json.compare(value_pos, 4, "null") == 0) {
        return "";
    }
    return "";
}

std::string ConfigApi::extract_json_section(const std::string& json, const std::string& key) const {
    std::string search_key = "\"" + key + "\"";
    size_t pos = json.find(search_key);
    if (pos == std::string::npos) {
        return "";
    }
    
    pos = json.find(':', pos);
    if (pos == std::string::npos) {
        return "";
    }
    
    size_t value_pos = pos + 1;
    while (value_pos < json.size() &&
           std::isspace(static_cast<unsigned char>(json[value_pos]))) {
        ++value_pos;
    }
    if (value_pos >= json.size()) {
        return "";
    }
    
    char start_char = json[value_pos];
    if (start_char == '{' || start_char == '[') {
        char open_char = start_char;
        char close_char = (start_char == '{') ? '}' : ']';
        int depth = 0;
        bool in_string = false;
        bool escape = false;
        for (size_t i = value_pos; i < json.size(); ++i) {
            char ch = json[i];
            if (in_string) {
                if (escape) {
                    escape = false;
                } else if (ch == '\\') {
                    escape = true;
                } else if (ch == '"') {
                    in_string = false;
                }
                continue;
            }
            if (ch == '"') {
                in_string = true;
                continue;
            }
            if (ch == open_char) {
                depth++;
            } else if (ch == close_char) {
                depth--;
                if (depth == 0) {
                    return json.substr(value_pos, i - value_pos + 1);
                }
            }
        }
        return "";
    } else if (start_char == '"') {
        size_t start = value_pos + 1;
        size_t end = start;
        bool escape = false;
        while (end < json.size()) {
            char ch = json[end];
            if (escape) {
                escape = false;
                end++;
                continue;
            }
            if (ch == '\\') {
                escape = true;
                end++;
                continue;
            }
            if (ch == '"') {
                return json.substr(start, end - start);
            }
            end++;
        }
    } else {
        size_t end_pos = value_pos;
        while (end_pos < json.size() &&
               json[end_pos] != ',' &&
               json[end_pos] != '}' &&
               json[end_pos] != ']' &&
               !std::isspace(static_cast<unsigned char>(json[end_pos]))) {
            ++end_pos;
        }
        std::string value = json.substr(value_pos, end_pos - value_pos);
        while (!value.empty() && (value.back() == ' ' || value.back() == '\t')) {
            value.pop_back();
        }
        return value;
    }
    
    return "";
}

std::string ConfigApi::json_escape(const std::string& str) const {
    std::string result;
    result.reserve(str.length());
    for (char c : str) {
        switch (c) {
            case '"': result += "\\\""; break;
            case '\\': result += "\\\\"; break;
            case '\b': result += "\\b"; break;
            case '\f': result += "\\f"; break;
            case '\n': result += "\\n"; break;
            case '\r': result += "\\r"; break;
            case '\t': result += "\\t"; break;
            default: result += c; break;
        }
    }
    return result;
}

}
