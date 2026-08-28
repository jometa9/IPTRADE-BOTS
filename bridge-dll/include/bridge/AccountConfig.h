#pragma once

#include <string>
#include <vector>

namespace bridge {

struct SymbolModifier {
    bool enabled = false;
    std::string value;
    std::string action = "add";
};

struct AccountConfig {
    std::string role;
    std::string master_tcp_url;
    std::string lot_type = "multiplier";
    double lot_multiplier = 1.0;
    double fixed_lot = 0.0;
    bool reverse_trading = false;
    bool exact_match = false;
    SymbolModifier prefix;
    SymbolModifier suffix;
    std::vector<std::string> symbol_translations;

    bool is_master() const { return role == "master"; }
    bool is_slave() const { return role == "slave"; }
    bool is_pending() const { return role == "pending"; }
    bool is_valid() const { return !role.empty() && (role == "master" || role == "slave" || role == "pending"); }
};

}
