cmake_minimum_required(VERSION 3.20)

# macOS: Apple Silicon, macOS 12 and later (vcpkg's libraries are built for
# the same target, see triplets/arm64-osx.cmake). Ignored elsewhere.
set(CMAKE_OSX_ARCHITECTURES arm64 CACHE STRING "macOS architectures to build")
set(CMAKE_OSX_DEPLOYMENT_TARGET 12.0 CACHE STRING "Oldest macOS to support")

project(Gitgud
    VERSION 1.5.1
    DESCRIPTION "A moddable Git client with an XML+Lua GUI"
    LANGUAGES CXX)

# ---- Standard ------------------------------------------------------------
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Put binaries in a predictable place so resources/ can be found at runtime.
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)

# ---- Options -------------------------------------------------------------
option(GITGUD_UI_CEGUI  "Build the CEGUI UI backend" ON)
option(GITGUD_BUILD_TESTS "Build the unit tests"     ON)

# ---- Dependencies --------------------------------------------------------
# These resolve via vcpkg (see vcpkg.json) or your system package manager.
find_package(SDL2 CONFIG REQUIRED)
find_package(OpenGL REQUIRED)

# libgit2 via vcpkg uses the upstream config (libgit2Config.cmake). The exported
# imported target is 'libgit2::libgit2package' (a SHARED lib; vcpkg's applocal
# step copies git2.dll next to the exe at link time).
find_package(libgit2 CONFIG REQUIRED)

# Lua (vcpkg ships the standard FindLua module targets).
find_package(Lua REQUIRED)

# zlib (already shipped for libgit2) inflates downloaded update files.
find_package(ZLIB REQUIRED)

# stb (header-only) decodes PNG/JPEG/GIF/BMP/TGA for the image diff.
find_path(STB_INCLUDE_DIRS "stb_image.h" REQUIRED)

# CEGUI is not in vcpkg. We build it ourselves from source (the `master`
# branch, vendored as the third_party/cegui submodule) against vcpkg-provided
# glm/glew/pugixml/freetype instead of its own bundled "cegui-dependencies"
# pack -- see third_party/cegui-manifest/vcpkg.json and docs/BUILDING.md
# for the build steps. The upstream cmake/FindCEGUI.cmake module (also vendored in the
# submodule) predates this branch's module layout (e.g. it doesn't know about
# the PugiXML parser, and expects separate OpenGL/OpenGL3 renderer libs where
# this branch builds one merged CEGUIOpenGLRenderer), so rather than fight it
# we locate our known install layout directly.
if(GITGUD_UI_CEGUI)
    # Two installs of the same CEGUI source: Debug (`_d` suffix) and Release
    # (no suffix). MSVC can't mix debug and release CRTs across DLLs, so the
    # build type picks the matching one. Elsewhere one Release CEGUI serves
    # every build type.
    if(WIN32 AND CMAKE_BUILD_TYPE STREQUAL "Debug")
        set(_cegui_default_dir "${CMAKE_SOURCE_DIR}/third_party/cegui-install")
        set(_cegui_suffix "_d")
    else()
        set(_cegui_default_dir "${CMAKE_SOURCE_DIR}/third_party/cegui-install-release")
        set(_cegui_suffix "")
    endif()
    set(CEGUI_INSTALL_DIR "${_cegui_default_dir}"
        CACHE PATH "Prefix CEGUI was installed to (see docs/BUILDING.md)")

    find_path(CEGUI_INCLUDE_DIR NAMES CEGUI/CEGUI.h
        PATHS "${CEGUI_INSTALL_DIR}/include"
        PATH_SUFFIXES cegui-9999
        NO_DEFAULT_PATH)

    # Elsewhere the modules CEGUI loads at run time (window renderers, XML
    # parser, image codec) sit in lib/cegui-9999.0.
    set(CEGUI_LIB_DIR "${CEGUI_INSTALL_DIR}/lib")
    set(CEGUI_BIN_DIR "${CEGUI_INSTALL_DIR}/bin")

    find_library(CEGUI_BASE_LIBRARY            NAMES CEGUIBase-9999${_cegui_suffix}             PATHS ${CEGUI_LIB_DIR} PATH_SUFFIXES cegui-9999.0 NO_DEFAULT_PATH)
    find_library(CEGUI_CORE_WRS_LIBRARY        NAMES CEGUICoreWindowRendererSet${_cegui_suffix} PATHS ${CEGUI_LIB_DIR} PATH_SUFFIXES cegui-9999.0 NO_DEFAULT_PATH)
    find_library(CEGUI_OPENGL_RENDERER_LIBRARY NAMES CEGUIOpenGLRenderer-9999${_cegui_suffix}   PATHS ${CEGUI_LIB_DIR} PATH_SUFFIXES cegui-9999.0 NO_DEFAULT_PATH)
    find_library(CEGUI_PUGIXML_LIBRARY         NAMES CEGUIPugiXMLParser${_cegui_suffix}         PATHS ${CEGUI_LIB_DIR} PATH_SUFFIXES cegui-9999.0 NO_DEFAULT_PATH)
    find_library(CEGUI_STB_LIBRARY             NAMES CEGUISTBImageCodec${_cegui_suffix}         PATHS ${CEGUI_LIB_DIR} PATH_SUFFIXES cegui-9999.0 NO_DEFAULT_PATH)

    if(CEGUI_INCLUDE_DIR AND CEGUI_BASE_LIBRARY AND CEGUI_CORE_WRS_LIBRARY AND
       CEGUI_OPENGL_RENDERER_LIBRARY AND CEGUI_PUGIXML_LIBRARY AND CEGUI_STB_LIBRARY)
        set(CEGUI_FOUND TRUE)
        set(CEGUI_LIBRARIES
            ${CEGUI_BASE_LIBRARY}
            ${CEGUI_CORE_WRS_LIBRARY}
            ${CEGUI_OPENGL_RENDERER_LIBRARY}
            ${CEGUI_PUGIXML_LIBRARY}
            ${CEGUI_STB_LIBRARY})
        set(CEGUI_INCLUDE_DIRS ${CEGUI_INCLUDE_DIR})
        set(CEGUI_DATAFILES_DIR "${CEGUI_INSTALL_DIR}/share/cegui-9999")
        message(STATUS "Found CEGUI (built from source): ${CEGUI_INSTALL_DIR}")
    else()
        set(CEGUI_FOUND FALSE)
        message(WARNING "GITGUD_UI_CEGUI is ON but CEGUI wasn't found under "
            "${CEGUI_INSTALL_DIR}. Build+install it first (see docs/BUILDING.md).")
    endif()
endif()

# ---- Core library --------------------------------------------------------
# Everything UI-agnostic lives here so BOTH the app and the tests link it. This
# is the unit-testable heart of the project (Git engine, app state, Lua bridge).
add_library(gitgud_core STATIC
    src/git/Repository.cpp
    src/git/RepositoryRefs.cpp
    src/git/RepositoryNetwork.cpp
    src/git/RepositoryStaging.cpp
    src/git/RepositoryWorkflow.cpp
    src/git/RepositoryHistory.cpp
    src/git/RepositoryRewrite.cpp
    src/git/RepositoryModules.cpp
    src/git/RepositoryTree.cpp
    src/git/RepositoryShelves.cpp
    src/git/RepositoryRevisionGraph.cpp
    src/git/CommitGraph.cpp
    src/git/CommitSigning.cpp
    src/git/LfsFilter.cpp
    src/p4/P4Command.cpp
    src/p4/P4Workspace.cpp
    src/p4/P4WorkspaceHistory.cpp
    src/p4/P4WorkspaceBranches.cpp
    src/p4/P4WorkspaceChanges.cpp
    src/app/EventBus.cpp
    src/app/TaskRunner.cpp
    src/app/UiPackages.cpp
    src/app/Updater.cpp
    src/update/UpdateCore.cpp
    src/lua/LuaEngine.cpp
    src/lua/LuaUpdateBindings.cpp
    src/lua/LuaP4Bindings.cpp
    src/lua/LuaRepoBindings.cpp
    src/lua/LuaUiBindings.cpp
    src/lua/LuaFeatureBindings.cpp
    src/lua/LuaAppBindings.cpp
    src/platform/CredentialStore.cpp
    src/platform/Shell.cpp
    src/platform/CrashHandler.cpp
    src/platform/Process.cpp
    src/platform/Http.cpp
    src/imaging/ImageDiff.cpp
    src/imaging/GraphRenderer.cpp
    src/imaging/Raster.cpp
    src/imaging/RevisionGraphRenderer.cpp
)

if(WIN32)
    # Windows Credential Manager (CredReadW/CredWriteW) lives in advapi32;
    # the shell helpers (recycle bin, folder picker) need shell32/ole32;
    # downloads use winhttp, checksums bcrypt.
    target_link_libraries(gitgud_core PUBLIC advapi32 shell32 ole32 dbghelp winhttp bcrypt)
else()
    # The shell helpers use SDL's clipboard; the Linux credential store loads
    # libsecret at run time.
    target_link_libraries(gitgud_core PUBLIC SDL2::SDL2 ${CMAKE_DL_LIBS})
endif()

target_include_directories(gitgud_core PUBLIC
    ${CMAKE_SOURCE_DIR}/src
    ${LUA_INCLUDE_DIR}
)
target_include_directories(gitgud_core PRIVATE ${STB_INCLUDE_DIRS})

# gitgud.version in Lua (About, updates) comes from project(... VERSION).
target_compile_definitions(gitgud_core PRIVATE GITGUD_VERSION="${PROJECT_VERSION}")

# PUBLIC so consumers (gitgud, gitgud_tests) inherit these transitively.
target_link_libraries(gitgud_core PUBLIC
    libgit2::libgit2package
    ${LUA_LIBRARIES}
    ZLIB::ZLIB
)

# ---- Update patcher --------------------------------------------------------
# gitgud-patcher.exe applies a downloaded update while GitGud is closed (see
# src/patcher/PatcherMain.cpp). It runs from a copy outside the install
# folder, so it links the C runtime statically and uses nothing but Windows.
if(WIN32)
    add_executable(gitgud-patcher WIN32
        src/patcher/PatcherMain.cpp
        src/update/UpdateCore.cpp
        resources/icon/gitgud.rc)
    target_include_directories(gitgud-patcher PRIVATE ${CMAKE_SOURCE_DIR}/src)
    target_link_libraries(gitgud-patcher PRIVATE bcrypt shell32 advapi32 user32)
    set_property(TARGET gitgud-patcher PROPERTY
        MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
    if(MSVC)
        target_link_options(gitgud-patcher PRIVATE "/PDBALTPATH:%_PDB%")
    endif()
endif()

# ---- Application ---------------------------------------------------------
# WIN32: GUI subsystem on Windows (no console window pops up). SDL2main
# provides the WinMain shim that forwards to our regular main(). Dev logging
# survives: main.cpp re-attaches to the parent shell's console when launched
# from one, and GITGUD_CONSOLE=1 forces a dedicated console window.
add_executable(gitgud WIN32 src/main.cpp)

# Windows: embed the Jera-rune app icon (Explorer / taskbar / Alt-Tab).
if(WIN32)
    enable_language(RC)
    target_sources(gitgud PRIVATE resources/icon/gitgud.rc)
endif()

# MSVC records the .pdb's absolute path in the exe; keep only its file name.
# Debuggers match symbols by GUID and still look next to the exe.
if(MSVC)
    target_link_options(gitgud PRIVATE "/PDBALTPATH:%_PDB%")
endif()

if(GITGUD_UI_CEGUI)
    target_sources(gitgud PRIVATE src/ui/cegui/CeguiBackend.cpp)
    target_compile_definitions(gitgud PRIVATE GITGUD_UI_CEGUI=1)
endif()

target_link_libraries(gitgud PRIVATE
    gitgud_core
    SDL2::SDL2
    SDL2::SDL2main
    OpenGL::GL
)

if(GITGUD_UI_CEGUI AND CEGUI_FOUND)
    target_link_libraries(gitgud PRIVATE ${CEGUI_LIBRARIES})
    target_include_directories(gitgud PRIVATE ${CEGUI_INCLUDE_DIRS})
    # CeguiBackend needs this to point CEGUI's resource groups (schemes,
    # imagesets, fonts, looknfeel) at the datafiles CEGUI itself installed --
    # we don't vendor a copy of the TaharezLook skin in resources/. Relative to
    # the exe's folder, so the build machine's absolute path isn't baked in.
    file(RELATIVE_PATH _cegui_data_rel
        ${CMAKE_RUNTIME_OUTPUT_DIRECTORY} ${CEGUI_DATAFILES_DIR})
    target_compile_definitions(gitgud PRIVATE
        GITGUD_CEGUI_DATAFILES_REL="${_cegui_data_rel}")

    # Elsewhere CEGUI's shared libraries stay in its install's lib folder and
    # the build finds them through its RPATH.
    if(NOT WIN32)
        set_target_properties(gitgud PROPERTIES
            BUILD_RPATH "${CEGUI_LIB_DIR};${CEGUI_LIB_DIR}/cegui-9999.0")
    endif()
endif()

if(WIN32 AND GITGUD_UI_CEGUI AND CEGUI_FOUND)
    # CEGUI's own DLLs aren't a vcpkg package, so vcpkg's applocal step won't
    # copy them; do it ourselves alongside gitgud.exe.
    add_custom_command(TARGET gitgud POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_directory
            ${CEGUI_BIN_DIR}
            $<TARGET_FILE_DIR:gitgud>
        COMMENT "Copying CEGUI runtime DLLs to build output")

    # vcpkg's applocal step only follows gitgud.exe's own imports, so the vcpkg
    # DLLs that only CEGUI needs (FreeType and its compression/PNG libraries,
    # GLEW, pugixml for the XML parser module CEGUI loads at runtime) would be
    # missing from a clean build. Run the same step on each CEGUI DLL. (The
    # root manifest lists these packages, so they're in this build's tree.)
    get_filename_component(_vcpkg_buildsystems "${CMAKE_TOOLCHAIN_FILE}" DIRECTORY)
    file(GLOB _cegui_dlls "${CEGUI_BIN_DIR}/*.dll")
    foreach(_dll IN LISTS _cegui_dlls)
        get_filename_component(_dll_name "${_dll}" NAME)
        add_custom_command(TARGET gitgud POST_BUILD
            COMMAND powershell -NoProfile -ExecutionPolicy Bypass
                -File "${_vcpkg_buildsystems}/msbuild/applocal.ps1"
                -targetBinary "$<TARGET_FILE_DIR:gitgud>/${_dll_name}"
                -installedDir "${VCPKG_INSTALLED_DIR}/${VCPKG_TARGET_TRIPLET}$<$<CONFIG:Debug>:/debug>/bin"
                -OutVariable out
            VERBATIM)
    endforeach()
endif()

# Mirror resources/ (layouts, scripts, skin) and docs/ next to the binary on
# EVERY build, even when no code changed, and drop files deleted from the
# source tree. The running app hot-reloads from this copy. (docs/ ships so
# the Help menu can list and open them - see gitgud.docs().)
add_custom_target(gitgud_resources ALL
    COMMAND ${CMAKE_COMMAND} -E rm -rf ${CMAKE_RUNTIME_OUTPUT_DIRECTORY}/resources
    COMMAND ${CMAKE_COMMAND} -E copy_directory
        ${CMAKE_SOURCE_DIR}/resources ${CMAKE_RUNTIME_OUTPUT_DIRECTORY}/resources
    COMMAND ${CMAKE_COMMAND} -E rm -rf ${CMAKE_RUNTIME_OUTPUT_DIRECTORY}/docs
    COMMAND ${CMAKE_COMMAND} -E copy_directory
        ${CMAKE_SOURCE_DIR}/docs ${CMAKE_RUNTIME_OUTPUT_DIRECTORY}/docs
    COMMENT "Syncing resources/ and docs/ to the build output")
add_dependencies(gitgud gitgud_resources)
if(TARGET gitgud-patcher)
    add_dependencies(gitgud gitgud-patcher)
endif()

# The few stock CEGUI data files GitGud uses (the Vanilla imageset, the
# DejaVu fallback font, the XML schemas) go next to the exe too, so a build
# folder copied to another machine still runs; the app prefers this copy over
# the CEGUI install it was built against (see CeguiBackend::Initialize).
if(GITGUD_UI_CEGUI AND CEGUI_FOUND)
    set(_cegui_data_out ${CMAKE_RUNTIME_OUTPUT_DIRECTORY}/cegui-datafiles)
    add_custom_command(TARGET gitgud_resources POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E make_directory
            ${_cegui_data_out}/imagesets ${_cegui_data_out}/fonts ${_cegui_data_out}/xml_schemas
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            ${CEGUI_DATAFILES_DIR}/imagesets/Vanilla.imageset
            ${CEGUI_DATAFILES_DIR}/imagesets/vanilla.png
            ${_cegui_data_out}/imagesets
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            ${CEGUI_DATAFILES_DIR}/fonts/DejaVuSans-12.font
            ${CEGUI_DATAFILES_DIR}/fonts/DejaVuSans.ttf
            ${_cegui_data_out}/fonts
        COMMAND ${CMAKE_COMMAND} -E copy_directory
            ${CEGUI_DATAFILES_DIR}/xml_schemas ${_cegui_data_out}/xml_schemas
        COMMENT "Copying the CEGUI data files GitGud uses")
endif()

# ---- Linux packages ------------------------------------------------------
# `cpack -G "DEB;RPM"` in the build folder (package.sh does it all). The app
# and everything it loads live in /usr/lib/gitgud, laid out like the build's
# bin folder; /usr/bin/gitgud links to it. CEGUI's libraries go in lib/
# (found through the RPATH) and its run-time modules in lib/cegui-9999.0
# (CeguiBackend points CEGUI_MODULE_DIR there). GITGUD_GH_DIR names a folder
# holding the GitHub CLI (gh and its LICENSE) to bundle as <app>/gh.
if(UNIX AND NOT APPLE AND GITGUD_UI_CEGUI AND CEGUI_FOUND)
    set(GITGUD_GH_DIR "" CACHE PATH "Folder with the gh binary to bundle in Linux packages")
    set(_app_dir lib/gitgud)

    set_target_properties(gitgud PROPERTIES
        INSTALL_RPATH "$ORIGIN/lib;$ORIGIN/lib/cegui-9999.0")
    install(TARGETS gitgud RUNTIME DESTINATION ${_app_dir})
    install(DIRECTORY ${CMAKE_RUNTIME_OUTPUT_DIRECTORY}/resources
        ${CMAKE_RUNTIME_OUTPUT_DIRECTORY}/docs
        ${CMAKE_RUNTIME_OUTPUT_DIRECTORY}/cegui-datafiles
        DESTINATION ${_app_dir})
    install(DIRECTORY ${CEGUI_LIB_DIR}/ DESTINATION ${_app_dir}/lib
        FILES_MATCHING PATTERN "*.so*"
        PATTERN "pkgconfig" EXCLUDE)
    if(GITGUD_GH_DIR)
        install(PROGRAMS ${GITGUD_GH_DIR}/gh DESTINATION ${_app_dir}/gh)
        install(FILES ${GITGUD_GH_DIR}/LICENSE DESTINATION ${_app_dir}/gh)
    endif()

    install(CODE "file(MAKE_DIRECTORY \"\$ENV{DESTDIR}\${CMAKE_INSTALL_PREFIX}/bin\")
        file(CREATE_LINK ../${_app_dir}/gitgud
            \"\$ENV{DESTDIR}\${CMAKE_INSTALL_PREFIX}/bin/gitgud\" SYMBOLIC)")
    install(FILES installer/linux/gitgud.desktop DESTINATION share/applications)
    # Folders other packages own too (the RPM must not claim them).
    set(_shared_dirs /usr/share/applications /usr/share/icons /usr/share/icons/hicolor
        /usr/share/doc)
    foreach(_size 16 24 32 48 64 256)
        install(FILES installer/linux/icons/${_size}x${_size}/gitgud.png
            DESTINATION share/icons/hicolor/${_size}x${_size}/apps)
        list(APPEND _shared_dirs /usr/share/icons/hicolor/${_size}x${_size}
            /usr/share/icons/hicolor/${_size}x${_size}/apps)
    endforeach()
    install(FILES LICENSE THIRD_PARTY_NOTICES.txt DESTINATION share/doc/gitgud-desktop)

    set(CPACK_PACKAGE_NAME gitgud-desktop)
    set(CPACK_PACKAGE_VENDOR "Tim")
    set(CPACK_PACKAGE_CONTACT "Tim <28170612+Forasp@users.noreply.github.com>")
    set(CPACK_PACKAGE_DESCRIPTION_SUMMARY "${PROJECT_DESCRIPTION}")
    set(CPACK_PACKAGE_HOMEPAGE_URL "https://github.com/Forasp/GitGudDesktop")
    set(CPACK_PACKAGING_INSTALL_PREFIX /usr)
    set(CPACK_STRIP_FILES ON)

    set(CPACK_DEBIAN_FILE_NAME DEB-DEFAULT)
    set(CPACK_DEBIAN_PACKAGE_SECTION vcs)
    set(CPACK_DEBIAN_PACKAGE_SHLIBDEPS ON)
    set(CPACK_DEBIAN_PACKAGE_SHLIBDEPS_PRIVATE_DIRS
        "${CEGUI_LIB_DIR};${CEGUI_LIB_DIR}/cegui-9999.0")
    # Used when present: git for the console and LFS, LFS, commit signing,
    # opening files, saved passwords, the folder picker.
    set(CPACK_DEBIAN_PACKAGE_RECOMMENDS "git, git-lfs, gnupg, xdg-utils, libsecret-1-0, zenity")

    set(CPACK_RPM_FILE_NAME RPM-DEFAULT)
    set(CPACK_RPM_PACKAGE_LICENSE "MIT")
    set(CPACK_RPM_PACKAGE_GROUP "Development/Tools")
    # Recommends (installed by default, like the .deb's) go straight into the
    # spec header: CPack has no RECOMMENDS variable, and its weak-dependency
    # probe runs an RPM_EXECUTABLE it never sets, so it drops SUGGESTS too.
    set(_rpm_recommends "")
    foreach(_package git git-lfs gnupg2 xdg-utils libsecret zenity)
        string(APPEND _rpm_recommends "Recommends: ${_package}\n")
    endforeach()
    # The bundled CEGUI libraries are private: neither provide nor require
    # them from the system.
    set(CPACK_RPM_SPEC_MORE_DEFINE
        "%global __provides_exclude_from ^/usr/lib/gitgud/.*$
%global __requires_exclude ^libCEGUI.*$
${_rpm_recommends}")
    set(CPACK_RPM_EXCLUDE_FROM_AUTO_FILELIST_ADDITION ${_shared_dirs})
    include(CPack)
endif()

# ---- Tests ---------------------------------------------------------------
if(GITGUD_BUILD_TESTS)
    enable_testing()
    add_subdirectory(tests)
endif()
