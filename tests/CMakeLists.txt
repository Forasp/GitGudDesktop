# Unit tests for gitgud_core. Uses Catch2 v3 from vcpkg.
find_package(Catch2 3 CONFIG REQUIRED)

add_executable(gitgud_tests
    test_runner.cpp
    test_repository.cpp
    test_engine_extended.cpp
    test_network_local.cpp
    test_taskrunner.cpp
    test_workflows.cpp
    test_features.cpp
    test_depot.cpp
    test_p4.cpp
    test_colourmap.cpp
    test_textspans.cpp
    test_json.cpp
    test_profiler.cpp
    test_relaunch.cpp
    test_bare_store.cpp
    test_voice_pcm.cpp
    test_audio.cpp
    test_claude_session.cpp
    test_claude_transcripts.cpp
    test_chat_images.cpp
    test_mcp_tools.cpp
    test_speech.cpp
    test_speech_turbo.cpp
)

# The updater is Windows only (BCrypt signatures, gitgud-patcher.exe).
if(WIN32)
    target_sources(gitgud_tests PRIVATE test_update.cpp)
endif()

# Voice audio is Windows only for now; the sessions' tests talk to a fake
# speech engine over in-memory links.
if(WIN32)
    target_sources(gitgud_tests PRIVATE test_voice.cpp)
endif()

# ChildProcess is Windows only for now; its tests drive a small echo child.
if(WIN32)
    add_executable(gitgud_test_child child_echo.cpp)
    target_sources(gitgud_tests PRIVATE test_child_process.cpp)
    add_dependencies(gitgud_tests gitgud_test_child)
    target_compile_definitions(gitgud_tests PRIVATE
        GITGUD_TEST_CHILD="$<TARGET_FILE:gitgud_test_child>")

    # A stand-in for claude for the Claude Code session's tests.
    # The tool pipe: its "settings" scenario calls the app's settings tools.
    # A stand-in for the GitHub CLI for tests/ui/signin.lua (GITGUD_TEST_GH).
    add_executable(gitgud_test_gh fake_gh.cpp)
    add_dependencies(gitgud_tests gitgud_test_gh)

    add_executable(gitgud_test_claude fake_claude.cpp ${CMAKE_SOURCE_DIR}/src/app/Json.cpp
        ${CMAKE_SOURCE_DIR}/src/agent/ToolPipe.cpp)
    target_include_directories(gitgud_test_claude PRIVATE ${CMAKE_SOURCE_DIR}/src)
    target_link_libraries(gitgud_test_claude PRIVATE gitgud_profiler)
    add_dependencies(gitgud_tests gitgud_test_claude)
    target_compile_definitions(gitgud_tests PRIVATE
        GITGUD_TEST_CLAUDE="$<TARGET_FILE:gitgud_test_claude>")

    # The MCP server for the Git tools, run end to end.
    add_dependencies(gitgud_tests gitgud-mcp)
    target_compile_definitions(gitgud_tests PRIVATE
        GITGUD_TEST_MCP="$<TARGET_FILE:gitgud-mcp>")
endif()

# The Keychain store is macOS only.
if(APPLE)
    target_sources(gitgud_tests PRIVATE test_keychain.cpp)
endif()

target_link_libraries(gitgud_tests PRIVATE
    gitgud_core
    Catch2::Catch2WithMain
)

# Register each TEST_CASE with CTest so they show up in VS Test Explorer and
# `ctest` on the command line.
include(Catch)
catch_discover_tests(gitgud_tests)
