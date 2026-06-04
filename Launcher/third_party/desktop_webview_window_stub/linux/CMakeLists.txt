cmake_minimum_required(VERSION 3.10)

set(PROJECT_NAME "desktop_webview_window")
project(${PROJECT_NAME} LANGUAGES CXX C)

# Must match the upstream plugin so the generated registrant resolves the same
# symbol (desktop_webview_window_plugin_register_with_registrar).
set(PLUGIN_NAME "desktop_webview_window_plugin")

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(PkgConfig REQUIRED)
# GTK only. No webkit2gtk on purpose: that is the whole point of this stub.
pkg_check_modules(GTK REQUIRED IMPORTED_TARGET gtk+-3.0)

add_library(${PLUGIN_NAME} SHARED
  "desktop_webview_window_plugin_stub.cc"
)

if(COMMAND apply_standard_settings)
  apply_standard_settings(${PLUGIN_NAME})
endif()

set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)

target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_include_directories(${PLUGIN_NAME} PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")

target_link_libraries(${PLUGIN_NAME} PRIVATE flutter)
target_link_libraries(${PLUGIN_NAME} PRIVATE PkgConfig::GTK)

set(desktop_webview_window_bundled_libraries
  ""
  PARENT_SCOPE
)
