cmake_minimum_required(VERSION 3.22.1)
project(unitree_dds_bridge LANGUAGES C)

add_library(ddsc SHARED IMPORTED)
set_target_properties(
  ddsc
  PROPERTIES IMPORTED_LOCATION
             "${CMAKE_CURRENT_LIST_DIR}/../jniLibs/${ANDROID_ABI}/libddsc.so"
)

add_library(
  unitree_dds_bridge
  SHARED
  unitree_dds_bridge.c
  generated/unitree_api.c
)

target_include_directories(
  unitree_dds_bridge
  PRIVATE
  generated
  third_party/cyclonedds/include
)

find_library(log-lib log)
target_link_libraries(unitree_dds_bridge ddsc ${log-lib})

