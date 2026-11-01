# Build the corpus runner. cuda.h and libcuda come from the CUDA toolkit on the build machine; neither is in the
# repository.
cmake_minimum_required(VERSION 3.20)
project(kamui_runner C)
find_package(CUDAToolkit REQUIRED)
add_executable(runner runner.c)
set_target_properties(runner PROPERTIES C_STANDARD 11 C_STANDARD_REQUIRED YES)
target_compile_options(runner PRIVATE -O2 -Wall -Wextra)
target_link_libraries(runner PRIVATE CUDA::cuda_driver)
