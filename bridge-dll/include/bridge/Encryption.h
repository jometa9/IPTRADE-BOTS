#pragma once

#include <string>
#include <vector>

namespace bridge {

class Encryption {
public:

    static bool set_key(const std::string& key);

    static bool is_enabled();

    static std::string encrypt(const std::string& plaintext);

    static std::string decrypt(const std::string& encrypted_envelope);

    static void clear_key();

private:
    static std::string base64_encode(const std::vector<unsigned char>& data);
    static std::vector<unsigned char> base64_decode(const std::string& encoded);
    static std::vector<unsigned char> generate_iv();
    static std::string extract_json_string(const std::string& json, const std::string& key);

    static std::vector<unsigned char> encryption_key_;
    static bool key_set_;
};

}

