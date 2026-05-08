# Post-install hooks that must run after every plugin sub-directory has
# installed its files. CMake processes install() calls from the top-level
# scope before traversing sub-directory cmake_install.cmake files. By placing
# this directory after the include(flutter/generated_plugins.cmake) call, the
# generated cmake_install.cmake here ends up at the very tail of the install
# order — after all plugins have written their .so/binaries into the bundle.

# 1) Resolve the runtime symbol clash between flutter_js's pre-built
#    libquickjs_c_bridge_plugin.so and libmujs.so.3 on Ubuntu 24.04+.
#    libwebkit2gtk-4.1 (pulled transitively by libmedia_kit_video_plugin.so)
#    drags libmujs.so.3 into the process. libmujs and QuickJS both export
#    js_malloc/js_free/js_realloc/js_strdup with incompatible semantics, so
#    the dynamic linker hijacks QuickJS's allocator on first JS_NewContext()
#    and the app SIGSEGVs. We rebrand the four QuickJS symbols inside the
#    shipped bundle copy. patchelf rebuilds the GNU hash buckets, so the
#    loader can still find the renamed symbols.
find_program(PATCHELF_EXECUTABLE patchelf)
if(PATCHELF_EXECUTABLE)
  install(CODE "
    set(_qjs_lib \"${INSTALL_BUNDLE_LIB_DIR}/libquickjs_c_bridge_plugin.so\")
    if(EXISTS \"\${_qjs_lib}\")
      message(STATUS \"Renaming colliding QuickJS symbols in \${_qjs_lib}\")
      execute_process(
        COMMAND \"${PATCHELF_EXECUTABLE}\" --rename-dynamic-symbols
                \"${CMAKE_CURRENT_SOURCE_DIR}/../quickjs_symbol_renames.txt\"
                \"\${_qjs_lib}\"
        RESULT_VARIABLE _patchelf_rc)
      if(NOT _patchelf_rc EQUAL 0)
        message(FATAL_ERROR
          \"patchelf failed to rename QuickJS symbols in \${_qjs_lib}\")
      endif()
    else()
      message(WARNING
        \"libquickjs_c_bridge_plugin.so not found at \${_qjs_lib}; skipping symbol rename\")
    endif()
  " COMPONENT Runtime)
else()
  message(WARNING
    "patchelf not found; libquickjs_c_bridge_plugin.so will collide with "
    "libmujs.so.3 at runtime. Install patchelf >=0.18 to enable the fix.")
endif()


# 2) Stage the kyber CLI bundle next to the launcher.
#
# The Linux launch flow delegates the actual game start to the kyber_cli
# subprocess (see Launcher/lib/features/maxima/helper/maxima_helper.dart).
# That subprocess plus its sibling helpers (umu-wrapper, ea-auth-webview,
# the wine-helper.exe used for DLL injection, the maxima-bootstrap that
# runs the game inside the wine prefix) must all sit in the same `cli/`
# directory so module_path()-relative lookups inside the CLI resolve
# correctly.
#
# Layout produced (matches the kyber-bf2-linux reference repo):
#
#   bundle/cli/kyber_cli              (compiled by `dart build cli`)
#   bundle/cli/librust_lib.so         (compiled by `dart build cli`)
#   bundle/cli/maxima-bootstrap       (cargo --release -p maxima-bootstrap)
#   bundle/cli/wine-helper.exe        (vendored from CLI/cli_payload/)
#   bundle/cli/umu-wrapper.sh         (vendored)
#   bundle/cli/ea-auth-webview.py     (vendored)
#   bundle/cli/kyber-auth-helper.sh   (vendored)
#   bundle/cli/bin/xdg-open           (vendored, intercepts EA OAuth URLs)
#
# Pre-condition: `dart build cli` must have been run inside Kyber/CLI/
# and `cargo build --release -p maxima-bootstrap --target
# x86_64-unknown-linux-gnu` inside Kyber/ThirdParty/Maxima/. The hook
# warns (and skips) when expected outputs are missing, so a launcher-only
# build still succeeds.
set(_KYBER_REPO_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../..")
set(_CLI_BUILD_BUNDLE
  "${_KYBER_REPO_ROOT}/CLI/build/cli/linux_x64/bundle")
set(_CLI_PAYLOAD "${_KYBER_REPO_ROOT}/CLI/cli_payload")
set(_MAXIMA_BOOTSTRAP_BIN
  "${_KYBER_REPO_ROOT}/ThirdParty/Maxima/target/x86_64-unknown-linux-gnu/release/maxima-bootstrap")

install(CODE "
  set(_cli_dst \"${CMAKE_INSTALL_PREFIX}/cli\")
  file(MAKE_DIRECTORY \"\${_cli_dst}/bin\")

  # dart build cli output: bin/kyber_cli + lib/librust_lib.so
  if(EXISTS \"${_CLI_BUILD_BUNDLE}/bin/kyber_cli\")
    file(INSTALL
      \"${_CLI_BUILD_BUNDLE}/bin/kyber_cli\"
      DESTINATION \"\${_cli_dst}\"
      USE_SOURCE_PERMISSIONS)
    file(INSTALL
      \"${_CLI_BUILD_BUNDLE}/lib/librust_lib.so\"
      DESTINATION \"\${_cli_dst}\")
  else()
    message(WARNING
      \"kyber_cli not found at ${_CLI_BUILD_BUNDLE}/bin/kyber_cli; \"
      \"the Linux launch flow will fail at runtime. Run \`dart build cli\` \"
      \"inside Kyber/CLI/ before flutter build linux.\")
  endif()

  if(EXISTS \"${_MAXIMA_BOOTSTRAP_BIN}\")
    file(INSTALL
      \"${_MAXIMA_BOOTSTRAP_BIN}\"
      DESTINATION \"\${_cli_dst}\"
      USE_SOURCE_PERMISSIONS)
  else()
    message(WARNING
      \"maxima-bootstrap not found at ${_MAXIMA_BOOTSTRAP_BIN}; \"
      \"run \`cargo build --release -p maxima-bootstrap --target \"
      \"x86_64-unknown-linux-gnu\` inside Kyber/ThirdParty/Maxima/.\")
  endif()

  foreach(_payload_file
    umu-wrapper.sh
    ea-auth-webview.py
    kyber-auth-helper.sh
    wine-helper.exe)
    if(EXISTS \"${_CLI_PAYLOAD}/\${_payload_file}\")
      file(INSTALL
        \"${_CLI_PAYLOAD}/\${_payload_file}\"
        DESTINATION \"\${_cli_dst}\"
        USE_SOURCE_PERMISSIONS)
    endif()
  endforeach()

  if(EXISTS \"${_CLI_PAYLOAD}/bin/xdg-open\")
    file(INSTALL
      \"${_CLI_PAYLOAD}/bin/xdg-open\"
      DESTINATION \"\${_cli_dst}/bin\"
      USE_SOURCE_PERMISSIONS)
  endif()

  # Linux NXM (nxm://) protocol bridge. Bash script that drops the URL
  # into \$XDG_RUNTIME_DIR/kyber/nxm-response; the launcher's inotify
  # watcher (ProtocolHelper._startLinuxNxmWatcher) picks it up.
  if(EXISTS \"${CMAKE_CURRENT_SOURCE_DIR}/../nxm_handler.sh\")
    file(INSTALL
      \"${CMAKE_CURRENT_SOURCE_DIR}/../nxm_handler.sh\"
      DESTINATION \"\${_cli_dst}/bin\"
      USE_SOURCE_PERMISSIONS)
  endif()

  # Linux self-update sidecar. Swaps the staged version into the
  # `current` symlink under \$HOME/.local/share/kyber/launcher and
  # re-execs the new launcher binary. Called both from the wrapper
  # (cold start with pending update) and from the running launcher
  # right before it exits to apply.
  if(EXISTS \"${CMAKE_CURRENT_SOURCE_DIR}/../update_apply.sh\")
    file(INSTALL
      \"${CMAKE_CURRENT_SOURCE_DIR}/../update_apply.sh\"
      DESTINATION \"\${_cli_dst}/bin\"
      USE_SOURCE_PERMISSIONS)
  endif()

  # Launcher entry-point wrapper. Prefers the per-user self-update
  # slot at ~/.local/share/kyber/launcher/current/kyber_launcher over
  # the system bundle; the .deb installer symlinks /usr/bin/kyber-bf2
  # to this script. Inside the launcher bundle itself it sits at
  # cli/bin/kyber-bf2 so devs can launch the same way.
  if(EXISTS \"${CMAKE_CURRENT_SOURCE_DIR}/../kyber-bf2\")
    file(INSTALL
      \"${CMAKE_CURRENT_SOURCE_DIR}/../kyber-bf2\"
      DESTINATION \"\${_cli_dst}/bin\"
      USE_SOURCE_PERMISSIONS)
  endif()
" COMPONENT Runtime)
