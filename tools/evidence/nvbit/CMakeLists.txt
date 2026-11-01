# Our NVBit tools, built against an NVBit release (NVBIT_PATH, set in the H100 job image).
#     cmake -S tools/evidence/nvbit -B <build> -DCMAKE_BUILD_TYPE=Release && cmake --build <build>
cmake_minimum_required(VERSION 3.29)
project(kamui_nvbit_tools LANGUAGES CXX CUDA)
find_package(CUDAToolkit REQUIRED)
set(NVBIT_PATH "$ENV{NVBIT_PATH}" CACHE PATH "NVBit release directory")
if(NOT EXISTS "${NVBIT_PATH}/tools/cmake/NVBitTool.cmake")
  message(FATAL_ERROR "set NVBIT_PATH to an NVBit 1.8 release directory")
endif()
set(NVBIT_TOOL_CUDA_ARCHITECTURES "90" CACHE STRING "CUDA architectures for the tools")
include("${NVBIT_PATH}/tools/cmake/NVBitTool.cmake")
add_subdirectory(dump_cubin)
