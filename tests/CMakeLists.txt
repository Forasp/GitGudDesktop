# Unit tests for gitgud_core. Uses Catch2 v3 from vcpkg.
find_package(Catch2 3 CONFIG REQUIRED)

add_executable(gitgud_tests
    test_repository.cpp
    test_engine_extended.cpp
    test_network_local.cpp
    test_taskrunner.cpp
    test_workflows.cpp
    test_features.cpp
    test_depot.cpp
    test_update.cpp
    test_p4.cpp
)

target_link_libraries(gitgud_tests PRIVATE
    gitgud_core
    Catch2::Catch2WithMain
)

# Register each TEST_CASE with CTest so they show up in VS Test Explorer and
# `ctest` on the command line.
include(Catch)
catch_discover_tests(gitgud_tests)
