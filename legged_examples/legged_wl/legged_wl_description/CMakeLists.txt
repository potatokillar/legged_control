cmake_minimum_required(VERSION 3.10)
project(legged_wl_description)

find_package(catkin REQUIRED)

catkin_package()

install(
        DIRECTORY meshes urdf
        DESTINATION ${CATKIN_PACKAGE_SHARE_DESTINATION}
)
