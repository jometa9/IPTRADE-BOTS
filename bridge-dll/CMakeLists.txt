cmake_minimum_required(VERSION 3.23)
project(copybridge LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_WINDOWS_EXPORT_ALL_SYMBOLS ON)

option(COPYBRIDGE_BUILD_TESTS "Build unit tests" OFF)

add_library(copybridge SHARED
    src/ApiAuth.cpp
    src/BridgeServer.cpp
    src/CommandQueue.cpp
    src/Encryption.cpp
    src/HttpServer.cpp
    src/LocalEventPoster.cpp
    src/ConfigApi.cpp
    src/TcpServer.cpp
    src/TcpClient.cpp
    src/HeartbeatService.cpp
    src/SlaveConverter.cpp
    src/dllmain.cpp
)

target_include_directories(copybridge
    PUBLIC
        ${CMAKE_CURRENT_SOURCE_DIR}/include
    PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/src
)

target_compile_definitions(copybridge PRIVATE _WIN32_WINNT=0x0601 WIN32_LEAN_AND_MEAN)

# Enable structured exception handling for __try/__except
target_compile_options(copybridge PRIVATE /EHa)

target_link_libraries(copybridge PRIVATE ws2_32 winhttp bcrypt)

if(COPYBRIDGE_BUILD_TESTS)
    enable_testing()
    add_executable(copybridge_tests tests/command_queue_tests.cpp)
    target_link_libraries(copybridge_tests PRIVATE copybridge)
    add_test(NAME CommandQueueTests COMMAND copybridge_tests)
endif()

