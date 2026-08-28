#pragma once

#include <string>
#include <unordered_map>
#include <set>
#include <mutex>
#include "AccountConfig.h"
#include "BridgeTypes.h"

namespace bridge {

class ConfigApi {
public:
    static ConfigApi& instance();

    bool get_config(const std::string& account_id, AccountConfig& config_out) const;
    bool set_config(const std::string& account_id, const AccountConfig& config);
    bool delete_config(const std::string& account_id);
    bool validate_config(const AccountConfig& config, std::string& error_message) const;
    bool has_config(const std::string& account_id) const;
    std::vector<std::string> get_all_account_ids() const;
    void load_all_configs();
    bool load_config_from_file(const std::string& account_id);
    void clear_from_memory(const std::string& account_id);
    void allow_config_load(const std::string& account_id);
    std::string get_config_directory() const;

private:
    ConfigApi();
    ~ConfigApi() = default;

    std::string get_config_file_path(const std::string& account_id) const;
    bool save_config_to_file(const std::string& account_id, const AccountConfig& config) const;
    bool load_config_from_file_impl(const std::string& account_id, AccountConfig& config_out) const;
    AccountConfig parse_config_json(const std::string& json, const char* source = nullptr) const;
    std::string config_to_json(const AccountConfig& config) const;
    std::string extract_json_string_value(const std::string& json, const std::string& key) const;
    std::string extract_json_section(const std::string& json, const std::string& key) const;
    std::string json_escape(const std::string& str) const;

    mutable std::mutex config_mutex_;
    std::unordered_map<std::string, AccountConfig> configs_;
    std::set<std::string> session_cleared_accounts_;
    std::string config_directory_;
    bool initialized_;
};

}
