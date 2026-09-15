cmake_minimum_required(VERSION 3.14)
project(chrnet_core LANGUAGES CXX)

# Native VPN machinery shared by the app (chrnet.exe) and the ChrNet service
# (chrnet_service.exe): the Xray process, TUN setup, routes, leak protection,
# the system proxy and the pipe protocol between the two.
add_library(chrnet_core STATIC
  "core_controller.cpp"
  "json.cpp"
  "log.cpp"
  "net_util.cpp"
  "pipe_protocol.cpp"
  "proxy_settings.cpp"
  "wfp_guard.cpp"
)
apply_standard_settings(chrnet_core)
target_compile_definitions(chrnet_core PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
target_compile_options(chrnet_core PRIVATE "/utf-8")
target_include_directories(chrnet_core PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}")
target_link_libraries(chrnet_core PUBLIC
  iphlpapi ws2_32 wininet fwpuclnt rpcrt4 advapi32)
