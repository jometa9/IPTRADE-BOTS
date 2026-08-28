#include "Bridge/Encryption.h"

#include <windows.h>
#include <bcrypt.h>
#include <random>
#include <sstream>
#include <iomanip>
#include <algorithm>

#pragma comment(lib, "Bcrypt.lib")

namespace bridge {

std::vector<unsigned char> Encryption::encryption_key_;
bool Encryption::key_set_ = false;

bool Encryption::set_key(const std::string& key) {
    if (key.empty()) {
        key_set_ = false;
        encryption_key_.clear();
        return true;
    }

    if (key.size() != 32) {

        std::string adjusted_key = key;
        if (adjusted_key.size() < 32) {
            adjusted_key.append(32 - adjusted_key.size(), '\0');
        } else {
            adjusted_key = adjusted_key.substr(0, 32);
        }
        encryption_key_.assign(adjusted_key.begin(), adjusted_key.end());
    } else {
        encryption_key_.assign(key.begin(), key.end());
    }

    key_set_ = true;
    return true;
}

bool Encryption::is_enabled() {
    return key_set_ && !encryption_key_.empty();
}

void Encryption::clear_key() {
    key_set_ = false;
    encryption_key_.clear();
}

std::vector<unsigned char> Encryption::generate_iv() {
    std::vector<unsigned char> iv(16);

    NTSTATUS status = BCryptGenRandom(
        NULL,
        iv.data(),
        static_cast<ULONG>(iv.size()),
        BCRYPT_USE_SYSTEM_PREFERRED_RNG
    );

    if (!BCRYPT_SUCCESS(status)) {

        std::random_device rd;
        std::mt19937 gen(rd());
        std::uniform_int_distribution<> dis(0, 255);
        for (auto& byte : iv) {
            byte = static_cast<unsigned char>(dis(gen));
        }
    }

    return iv;
}

std::string Encryption::base64_encode(const std::vector<unsigned char>& data) {
    static const char* chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    std::string result;
    result.reserve(((data.size() + 2) / 3) * 4);

    for (size_t i = 0; i < data.size(); i += 3) {
        unsigned int n = static_cast<unsigned int>(data[i]) << 16;
        if (i + 1 < data.size()) n |= static_cast<unsigned int>(data[i + 1]) << 8;
        if (i + 2 < data.size()) n |= static_cast<unsigned int>(data[i + 2]);

        result += chars[(n >> 18) & 0x3F];
        result += chars[(n >> 12) & 0x3F];
        result += (i + 1 < data.size()) ? chars[(n >> 6) & 0x3F] : '=';
        result += (i + 2 < data.size()) ? chars[n & 0x3F] : '=';
    }

    return result;
}

std::vector<unsigned char> Encryption::base64_decode(const std::string& encoded) {
    static const int decode_table[256] = {
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,62,-1,-1,-1,63,
        52,53,54,55,56,57,58,59,60,61,-1,-1,-1,-1,-1,-1,
        -1, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9,10,11,12,13,14,
        15,16,17,18,19,20,21,22,23,24,25,-1,-1,-1,-1,-1,
        -1,26,27,28,29,30,31,32,33,34,35,36,37,38,39,40,
        41,42,43,44,45,46,47,48,49,50,51,-1,-1,-1,-1,-1,
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1
    };

    std::vector<unsigned char> result;
    result.reserve((encoded.size() * 3) / 4);

    unsigned int buffer = 0;
    int bits_collected = 0;

    for (char c : encoded) {
        if (c == '=') break;
        int value = decode_table[static_cast<unsigned char>(c)];
        if (value == -1) continue;

        buffer = (buffer << 6) | value;
        bits_collected += 6;

        if (bits_collected >= 8) {
            bits_collected -= 8;
            result.push_back(static_cast<unsigned char>((buffer >> bits_collected) & 0xFF));
        }
    }

    return result;
}

std::string Encryption::encrypt(const std::string& plaintext) {
    if (!is_enabled() || plaintext.empty()) {
        return plaintext;
    }

    BCRYPT_ALG_HANDLE hAlgorithm = NULL;
    BCRYPT_KEY_HANDLE hKey = NULL;
    NTSTATUS status;
    std::string result;

    status = BCryptOpenAlgorithmProvider(
        &hAlgorithm,
        BCRYPT_AES_ALGORITHM,
        NULL,
        0
    );

    if (!BCRYPT_SUCCESS(status)) {
        return plaintext;
    }

    status = BCryptSetProperty(
        hAlgorithm,
        BCRYPT_CHAINING_MODE,
        (PUCHAR)BCRYPT_CHAIN_MODE_CBC,
        sizeof(BCRYPT_CHAIN_MODE_CBC),
        0
    );

    if (!BCRYPT_SUCCESS(status)) {
        BCryptCloseAlgorithmProvider(hAlgorithm, 0);
        return plaintext;
    }

    status = BCryptGenerateSymmetricKey(
        hAlgorithm,
        &hKey,
        NULL,
        0,
        const_cast<PUCHAR>(encryption_key_.data()),
        static_cast<ULONG>(encryption_key_.size()),
        0
    );

    if (!BCRYPT_SUCCESS(status)) {
        BCryptCloseAlgorithmProvider(hAlgorithm, 0);
        return plaintext;
    }

    std::vector<unsigned char> iv = generate_iv();
    std::vector<unsigned char> iv_copy = iv;

    ULONG blockSize = 16;
    ULONG paddedSize = static_cast<ULONG>(((plaintext.size() / blockSize) + 1) * blockSize);

    std::vector<unsigned char> input(paddedSize);
    memcpy(input.data(), plaintext.data(), plaintext.size());
    unsigned char padding = static_cast<unsigned char>(paddedSize - plaintext.size());
    for (ULONG i = static_cast<ULONG>(plaintext.size()); i < paddedSize; i++) {
        input[i] = padding;
    }

    std::vector<unsigned char> ciphertext(paddedSize);
    ULONG cbCiphertext = 0;

    status = BCryptEncrypt(
        hKey,
        input.data(),
        paddedSize,
        NULL,
        iv_copy.data(),
        static_cast<ULONG>(iv_copy.size()),
        ciphertext.data(),
        paddedSize,
        &cbCiphertext,
        0
    );

    if (BCRYPT_SUCCESS(status)) {
        ciphertext.resize(cbCiphertext);

        std::ostringstream json;
        json << "{\"encrypted\":true,\"iv\":\"";
        json << base64_encode(iv);
        json << "\",\"data\":\"";
        json << base64_encode(ciphertext);
        json << "\"}";
        result = json.str();
    } else {
        result = plaintext;
    }

    BCryptDestroyKey(hKey);
    BCryptCloseAlgorithmProvider(hAlgorithm, 0);

    return result;
}

std::string Encryption::extract_json_string(const std::string& json, const std::string& key) {
    std::string needle = "\"" + key + "\":\"";
    size_t pos = json.find(needle);
    if (pos == std::string::npos) return "";

    pos += needle.size();
    size_t end = json.find("\"", pos);
    if (end == std::string::npos) return "";

    return json.substr(pos, end - pos);
}

std::string Encryption::decrypt(const std::string& encrypted_envelope) {
    if (!is_enabled() || encrypted_envelope.empty()) {
        return encrypted_envelope;
    }

    if (encrypted_envelope.find("\"encrypted\":true") == std::string::npos &&
        encrypted_envelope.find("\"encrypted\": true") == std::string::npos) {
        return encrypted_envelope;
    }

    std::string iv_b64 = extract_json_string(encrypted_envelope, "iv");
    std::string data_b64 = extract_json_string(encrypted_envelope, "data");

    if (iv_b64.empty() || data_b64.empty()) {
        return encrypted_envelope;
    }

    std::vector<unsigned char> iv = base64_decode(iv_b64);
    std::vector<unsigned char> ciphertext = base64_decode(data_b64);

    if (iv.size() != 16 || ciphertext.empty()) {
        return encrypted_envelope;
    }

    BCRYPT_ALG_HANDLE hAlgorithm = NULL;
    BCRYPT_KEY_HANDLE hKey = NULL;
    NTSTATUS status;
    std::string result;

    status = BCryptOpenAlgorithmProvider(
        &hAlgorithm,
        BCRYPT_AES_ALGORITHM,
        NULL,
        0
    );

    if (!BCRYPT_SUCCESS(status)) {
        return encrypted_envelope;
    }

    status = BCryptSetProperty(
        hAlgorithm,
        BCRYPT_CHAINING_MODE,
        (PUCHAR)BCRYPT_CHAIN_MODE_CBC,
        sizeof(BCRYPT_CHAIN_MODE_CBC),
        0
    );

    if (!BCRYPT_SUCCESS(status)) {
        BCryptCloseAlgorithmProvider(hAlgorithm, 0);
        return encrypted_envelope;
    }

    status = BCryptGenerateSymmetricKey(
        hAlgorithm,
        &hKey,
        NULL,
        0,
        const_cast<PUCHAR>(encryption_key_.data()),
        static_cast<ULONG>(encryption_key_.size()),
        0
    );

    if (!BCRYPT_SUCCESS(status)) {
        BCryptCloseAlgorithmProvider(hAlgorithm, 0);
        return encrypted_envelope;
    }

    std::vector<unsigned char> plaintext(ciphertext.size());
    ULONG cbPlaintext = 0;

    status = BCryptDecrypt(
        hKey,
        ciphertext.data(),
        static_cast<ULONG>(ciphertext.size()),
        NULL,
        iv.data(),
        static_cast<ULONG>(iv.size()),
        plaintext.data(),
        static_cast<ULONG>(plaintext.size()),
        &cbPlaintext,
        0
    );

    if (BCRYPT_SUCCESS(status) && cbPlaintext > 0) {

        unsigned char padding = plaintext[cbPlaintext - 1];
        if (padding > 0 && padding <= 16) {
            cbPlaintext -= padding;
        }
        result.assign(plaintext.begin(), plaintext.begin() + cbPlaintext);
    } else {
        result = encrypted_envelope;
    }

    BCryptDestroyKey(hKey);
    BCryptCloseAlgorithmProvider(hAlgorithm, 0);

    return result;
}

}

