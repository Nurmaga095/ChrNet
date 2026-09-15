cmake_minimum_required(VERSION 3.14)
project(chrnet_service LANGUAGES CXX)

# LocalSystem service that runs the Xray core and owns the tunnel, so the app
# itself runs without administrator rights. Installed next to chrnet.exe.
add_executable(chrnet_service
  "pipe_server.cpp"
  "service_main.cpp"
)
apply_standard_settings(chrnet_service)
target_compile_definitions(chrnet_service PRIVATE
  NOMINMAX WIN32_LEAN_AND_MEAN "CHRNET_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_options(chrnet_service PRIVATE "/utf-8")
target_link_libraries(chrnet_service PRIVATE chrnet_core)
