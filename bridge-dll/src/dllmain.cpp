#include <winsock2.h>
#include <windows.h>

#include <cstdint>
#include <string>
#include <stdio.h>

#include "Bridge/BridgeServer.h"
#include "Bridge/HeartbeatService.h"

using namespace bridge;

namespace {

bool IsValidPointer(const void* ptr) {
    if (!ptr) {
        return false;
    }

    uintptr_t ptr_val = reinterpret_cast<uintptr_t>(ptr);
    if (ptr_val == 0xFFFFFFFF ||
        ptr_val == 0x00000000 ||
        ptr_val < 0x10000) {
        return false;
    }
    return true;
}

int SafeWideCharToMultiByte(const wchar_t* input, char* output, int output_size) {
    if (!IsValidPointer(input)) {
        return 0;
    }

    __try {
        return WideCharToMultiByte(CP_UTF8, 0, input, -1, output, output_size, nullptr, nullptr);
    }
    __except(EXCEPTION_EXECUTE_HANDLER) {
        return 0;
    }
}

std::string WideToUtf8(const wchar_t* input) {
    if (!IsValidPointer(input)) {
        return {};
    }

    int size_needed = SafeWideCharToMultiByte(input, nullptr, 0);
    if (size_needed <= 0) {
        return {};
    }

    std::string result(size_needed - 1, '\0');
    SafeWideCharToMultiByte(input, result.data(), size_needed);
    return result;
}

}

extern "C" {

__declspec(dllexport) int __stdcall InitRestServer(const wchar_t* external_url,
                                                   int min_port,
                                                   int max_port) {
    try {
        std::string url = WideToUtf8(external_url);
        int result = BridgeServer::instance().init(url, min_port, max_port, "");
        return result;
    } catch (...) {
        return -2;
    }
}

__declspec(dllexport) int __stdcall InitRestServerEx(const wchar_t* external_url,
                                                      int min_port,
                                                      int max_port,
                                                      const wchar_t* encryption_key) {
    try {
        std::string url = WideToUtf8(external_url);
        std::string key = WideToUtf8(encryption_key);
        int result = BridgeServer::instance().init(url, min_port, max_port, key);
        return result;
    } catch (...) {
        return -2;
    }
}

__declspec(dllexport) void __stdcall StopRestServer() {
    try {
        BridgeServer::instance().stop();
    } catch (...) {
    }
}

__declspec(dllexport) int __stdcall PollNextCommand(char* buffer, int buffer_len) {
    try {
        return BridgeServer::instance().poll_next_command(buffer, buffer_len);
    } catch (...) {
        return -1;
    }
}

__declspec(dllexport) int __stdcall AckCommand(long command_id,
                                               int result_code,
                                               const wchar_t* message,
                                               const wchar_t* data_json) {
    try {
        std::string message_utf8 = WideToUtf8(message);
        std::string data_utf8 = WideToUtf8(data_json);
        return BridgeServer::instance().ack_command(command_id, result_code, message_utf8, data_utf8);
    } catch (...) {
        return -1;
    }
}

__declspec(dllexport) int __stdcall PushLocalEvent(const wchar_t* json_event) {
    try {
        if (!IsValidPointer(json_event)) {
            return -1;
        }
        std::string event = WideToUtf8(json_event);
        if (event.empty()) {
            return -1;
        }
        return BridgeServer::instance().push_local_event(event);
    } catch (...) {
        return -1;
    }
}

__declspec(dllexport) int __stdcall GetAssignedPort() {
    try {
        return BridgeServer::instance().assigned_port();
    } catch (...) {
        return -1;
    }
}

__declspec(dllexport) void __stdcall SetTerminalConnected(int is_connected) {
    try {
        HeartbeatService::instance().set_terminal_connected(is_connected != 0);
    } catch (...) {
    }
}

__declspec(dllexport) int __stdcall SendReadyNotification(const wchar_t* account_json, int local_port) {
    try {
        if (!IsValidPointer(account_json)) {
            return -1;
        }
        std::string account = WideToUtf8(account_json);
        if (account.empty()) {
            return -1;
        }
        return BridgeServer::instance().send_ready_notification(account, local_port);
    } catch (...) {
        return -1;
    }
}

}

BOOL APIENTRY DllMain(HMODULE hModule,
                      DWORD ul_reason_for_call,
                      LPVOID lpReserved) {
    try {
        switch (ul_reason_for_call) {
            case DLL_PROCESS_DETACH:
                BridgeServer::instance().stop();
                break;
            default:
                break;
        }
    } catch (...) {
    }
    return TRUE;
}

