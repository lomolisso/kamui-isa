# Build the litmus runner. cuda.h and libcuda come from the CUDA toolkit on the build machine; neither is in the
# repository.
cmake_minimum_required(VERSION 3.20)
project(kamui_litmus_runner C)
find_package(CUDAToolkit REQUIRED)
add_executable(litmus_runner litmus_runner.c)
set_target_properties(litmus_runner PROPERTIES C_STANDARD 11 C_STANDARD_REQUIRED YES)
target_compile_options(litmus_runner PRIVATE -O2 -Wall -Wextra)
target_link_libraries(litmus_runner PRIVATE CUDA::cuda_driver)
