# CMake toolchain file for cross-compiling bdwgc to WebAssembly using
# the WASI SDK (https://github.com/WebAssembly/wasi-sdk).
#
# Usage (set WASI_SDK_PATH to your wasi-sdk installation):
#
#   cmake /path/to/bdwgc \
#       -DCMAKE_TOOLCHAIN_FILE=/path/to/bdwgc/cmake/toolchains/wasi.cmake \
#       -DWASI_SDK_PATH=/opt/wasi-sdk \
#       -DCMAKE_BUILD_TYPE=RelWithDebInfo \
#       -Denable_threads=OFF \
#       -Denable_munmap=OFF \
#       -Denable_dynamic_loading=OFF \
#       -Dbuild_cord=OFF \
#       -DBUILD_SHARED_LIBS=OFF
#
# The WASI SDK provides:
#   - clang/clang++ targeting wasm32-wasi
#   - wasm-ld linker
#   - wasi-libc (POSIX-compatible C library for WASI)
#   - wasi-sysroot (headers and libraries)
#
# Notes:
#   - Shared libraries are not supported on WASM; use -DBUILD_SHARED_LIBS=OFF.
#   - GC threads are not supported for standard wasm32-wasi; use
#     -Denable_threads=OFF.
#   - The GC relies on the C shadow stack for root scanning.  Compile
#     application code with -O0 or -fno-omit-frame-pointer so that
#     local pointer variables are spilled to the C shadow stack and
#     remain visible to the collector.  See doc/README.wasm.md for details.

# Locate wasi-sdk.
if (NOT DEFINED WASI_SDK_PATH)
  # Check well-known installation locations.
  if (EXISTS "/opt/wasi-sdk")
    set(WASI_SDK_PATH "/opt/wasi-sdk")
  elseif (EXISTS "$ENV{HOME}/wasi-sdk")
    set(WASI_SDK_PATH "$ENV{HOME}/wasi-sdk")
  else()
    message(FATAL_ERROR
      "WASI SDK not found. Set -DWASI_SDK_PATH=/path/to/wasi-sdk on the "
      "cmake command line, or install the SDK at /opt/wasi-sdk.")
  endif()
endif()

message(STATUS "Using WASI SDK: ${WASI_SDK_PATH}")

set(WASI_SDK_BIN "${WASI_SDK_PATH}/bin")
set(WASI_SYSROOT "${WASI_SDK_PATH}/share/wasi-sysroot")

# Target triple.
set(CMAKE_SYSTEM_NAME      "WASI")
set(CMAKE_SYSTEM_PROCESSOR "wasm32")
set(triple                 "wasm32-wasi")

# Toolchain binaries.
set(CMAKE_C_COMPILER   "${WASI_SDK_BIN}/clang"   CACHE FILEPATH "C compiler")
set(CMAKE_CXX_COMPILER "${WASI_SDK_BIN}/clang++" CACHE FILEPATH "C++ compiler")
set(CMAKE_AR           "${WASI_SDK_BIN}/llvm-ar"  CACHE FILEPATH "Archiver")
set(CMAKE_RANLIB       "${WASI_SDK_BIN}/llvm-ranlib" CACHE FILEPATH "Ranlib")
set(CMAKE_C_COMPILER_TARGET   ${triple} CACHE STRING "C compiler target triple")
set(CMAKE_CXX_COMPILER_TARGET ${triple} CACHE STRING "C++ compiler target triple")

# Sysroot and ABI flags.
set(CMAKE_SYSROOT "${WASI_SYSROOT}")
# -fno-omit-frame-pointer is required for correct GC root scanning.
# The GC scans the C shadow stack (from __builtin_frame_address(0) to
# STACKBOTTOM = __stack_high) to find live heap pointers.  Without this
# flag, the compiler may omit the shadow-stack frame for leaf functions
# and some optimized functions, causing their local pointer variables to
# reside only in WASM VM locals (which are not in linear memory and are
# therefore invisible to the GC).  A pointer that lives only in a WASM
# local can be collected prematurely, causing a use-after-free crash.
set(CMAKE_C_FLAGS_INIT   "--sysroot=${WASI_SYSROOT} -fno-omit-frame-pointer")
set(CMAKE_CXX_FLAGS_INIT "--sysroot=${WASI_SYSROOT} -fno-omit-frame-pointer")

# Linker flags: export the standard wasm-ld symbols required by bdwgc.
# The GC uses __global_base, __data_end, __stack_high, __stack_low, and
# __heap_base to locate the data section and the C shadow stack boundaries.
set(WASM_LD_GC_EXPORTS
    "--export=__global_base"
    "--export=__data_end"
    "--export=__stack_high"
    "--export=__stack_low"
    "--export=__heap_base")
string(JOIN " " WASM_LD_GC_EXPORTS_STR ${WASM_LD_GC_EXPORTS})
set(CMAKE_EXE_LINKER_FLAGS_INIT
    "-Wl,${WASM_LD_GC_EXPORTS_STR}")

# Tell CMake where to look for WASI system libraries.
set(CMAKE_FIND_ROOT_PATH "${WASI_SYSROOT}")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

# Static-only builds for WASM (shared libraries are not supported).
set(BUILD_SHARED_LIBS OFF CACHE BOOL "Build shared libraries" FORCE)

# Disable features that are incompatible with WASM/WASI.
set(enable_threads         OFF CACHE BOOL "Support threads" FORCE)
set(enable_munmap          OFF CACHE BOOL "Return page to the OS if empty for N collections" FORCE)
set(enable_dynamic_loading OFF CACHE BOOL "Enable tracing of dynamic library data roots" FORCE)
set(enable_handle_fork     OFF CACHE BOOL "Attempt to ensure a usable collector after fork()" FORCE)

# cord is a separate library and can be disabled if not needed.
# It is left enabled by default so users can opt-in, but it can be
# turned off with -Dbuild_cord=OFF.
