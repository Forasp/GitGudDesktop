# vcpkg's arm64-osx triplet, plus the oldest macOS the app supports. Without
# a deployment target vcpkg builds for the SDK's own macOS version, and the
# app couldn't link its libraries for an older one. Keep in step with
# CMAKE_OSX_DEPLOYMENT_TARGET in CMakeLists.txt and setup.sh.
set(VCPKG_TARGET_ARCHITECTURE arm64)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_LIBRARY_LINKAGE static)

set(VCPKG_CMAKE_SYSTEM_NAME Darwin)
set(VCPKG_OSX_ARCHITECTURES arm64)
set(VCPKG_OSX_DEPLOYMENT_TARGET 12.0)
