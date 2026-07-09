#!/usr/bin/env bash
set -euo pipefail

IMAGE="${IMAGE:-192.168.1.93/iiri/build_x86_arm_ros1:latest}"
PULL_IMAGE="${PULL_IMAGE:-0}"
BUILD_OCS2="${BUILD_OCS2:-0}"
BUILD_TARGETS="${BUILD_TARGETS:-legged_wl_description legged_controllers legged_gazebo}"
EXTRA_SOURCE_DIRS="${EXTRA_SOURCE_DIRS:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SIM_ROOT="$(cd "${REPO_DIR}/.." && pwd)"
HOST_WS="${HOST_WS:-${SIM_ROOT}/.docker_ros1_ws}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--pull] [--build-ocs2] [--targets "pkg_a pkg_b"]

Environment:
  IMAGE              Docker image to use. Default: ${IMAGE}
  HOST_WS            Host path for persistent catkin workspace. Default: ${HOST_WS}
  BUILD_TARGETS      Catkin targets. Default: ${BUILD_TARGETS}
  BUILD_OCS2         Build OCS2 prerequisites first when source is mounted. Default: ${BUILD_OCS2}
  EXTRA_SOURCE_DIRS  Colon-separated extra source directories to symlink into catkin_ws/src.

Examples:
  scripts/docker_build_ros1.sh
  BUILD_TARGETS="legged_wl_description" scripts/docker_build_ros1.sh
  BUILD_OCS2=1 scripts/docker_build_ros1.sh
  EXTRA_SOURCE_DIRS="/home/wl/workspace/ocs2:/home/wl/workspace/pinocchio:/home/wl/workspace/hpp-fcl:/home/wl/workspace/ocs2_robotic_assets" scripts/docker_build_ros1.sh
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pull)
      PULL_IMAGE=1
      shift
      ;;
    --build-ocs2)
      BUILD_OCS2=1
      shift
      ;;
    --targets)
      BUILD_TARGETS="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

mkdir -p "${HOST_WS}"

if [[ "${PULL_IMAGE}" == "1" ]]; then
  docker pull "${IMAGE}"
fi

docker_args=(
  --rm
  --entrypoint /bin/bash
  -v "${SIM_ROOT}:/workspace/legged_control_sim"
  -v "${HOST_WS}:/workspace/catkin_ws"
  -e "BUILD_TARGETS=${BUILD_TARGETS}"
  -e "BUILD_OCS2=${BUILD_OCS2}"
  -w /workspace/catkin_ws
)

container_extra_dirs=()
if [[ -n "${EXTRA_SOURCE_DIRS}" ]]; then
  IFS=":" read -ra host_extra_dirs <<< "${EXTRA_SOURCE_DIRS}"
  extra_index=0
  for dir in "${host_extra_dirs[@]}"; do
    if [[ -d "${dir}" ]]; then
      abs_dir="$(cd "${dir}" && pwd)"
      container_dir="/workspace/extra_sources/${extra_index}_$(basename "${abs_dir}")"
      docker_args+=(-v "${abs_dir}:${container_dir}")
      container_extra_dirs+=("${container_dir}")
      extra_index=$((extra_index + 1))
    else
      echo "WARN: extra source directory does not exist on host: ${dir}" >&2
    fi
  done
fi

CONTAINER_EXTRA_SOURCE_DIRS=""
if [[ ${#container_extra_dirs[@]} -gt 0 ]]; then
  CONTAINER_EXTRA_SOURCE_DIRS="$(IFS=:; echo "${container_extra_dirs[*]}")"
fi
docker_args+=(-e "CONTAINER_EXTRA_SOURCE_DIRS=${CONTAINER_EXTRA_SOURCE_DIRS}")

if [[ -t 0 && -t 1 ]]; then
  docker_args+=(-it)
fi

docker run "${docker_args[@]}" "${IMAGE}" -lc '
set -eo pipefail
export ROS_MASTER_URI="${ROS_MASTER_URI:-http://localhost:11311}"

if [[ -f /opt/ros/noetic/setup.bash ]]; then
  source /opt/ros/noetic/setup.bash
else
  echo "ERROR: /opt/ros/noetic/setup.bash not found in container." >&2
  exit 10
fi

set -u

if command -v catkin >/dev/null 2>&1; then
  BUILD_TOOL=catkin_tools
elif command -v catkin_make >/dev/null 2>&1; then
  BUILD_TOOL=catkin_make
else
  echo "ERROR: neither catkin nor catkin_make was found in container." >&2
  exit 11
fi

declare -a catkin_make_packages=()
append_package() {
  local package="$1"
  local existing
  for existing in "${catkin_make_packages[@]}"; do
    if [[ "${existing}" == "${package}" ]]; then
      return
    fi
  done
  catkin_make_packages+=("${package}")
}
has_package() {
  local package="$1"
  local existing
  for existing in "${catkin_make_packages[@]}"; do
    if [[ "${existing}" == "${package}" ]]; then
      return 0
    fi
  done
  return 1
}

for package in ${BUILD_TARGETS}; do
  append_package "${package}"
done
if has_package legged_controllers; then
  append_package qpoases_catkin
  append_package legged_common
  append_package legged_interface
  append_package legged_wbc
  append_package legged_estimation
fi
if has_package legged_gazebo; then
  append_package legged_common
fi
if has_package legged_wbc; then
  append_package qpoases_catkin
fi
if [[ ${#catkin_make_packages[@]} -gt 0 ]]; then
  WHITELIST_PACKAGES="$(IFS=";"; echo "${catkin_make_packages[*]}")"
else
  WHITELIST_PACKAGES="${BUILD_TARGETS// /;}"
fi
NEEDS_OCS2=0
for package in "${catkin_make_packages[@]}"; do
  case "${package}" in
    legged_interface|legged_wbc|legged_estimation|legged_controllers)
      NEEDS_OCS2=1
      break
      ;;
  esac
done

mkdir -p src
ln -sfn /workspace/legged_control_sim/legged_control src/legged_control

for name in ocs2 pinocchio hpp-fcl ocs2_robotic_assets; do
  if [[ -d "/workspace/legged_control_sim/${name}" ]]; then
    ln -sfn "/workspace/legged_control_sim/${name}" "src/${name}"
  fi
done

if [[ -n "${CONTAINER_EXTRA_SOURCE_DIRS}" ]]; then
  IFS=":" read -ra extra_dirs <<< "${CONTAINER_EXTRA_SOURCE_DIRS}"
  for dir in "${extra_dirs[@]}"; do
    if [[ -d "${dir}" ]]; then
      ln -sfn "${dir}" "src/$(basename "${dir}")"
    else
      echo "WARN: extra source directory does not exist: ${dir}" >&2
    fi
  done
fi

if [[ "${BUILD_TOOL}" == "catkin_tools" ]]; then
  catkin config -DCMAKE_BUILD_TYPE=RelWithDebInfo
fi

if [[ "${NEEDS_OCS2}" == "1" ]] && ! rospack find ocs2_legged_robot_ros >/dev/null 2>&1; then
  if [[ "${BUILD_OCS2}" == "1" && -d src/ocs2 ]]; then
    if [[ "${BUILD_TOOL}" == "catkin_tools" ]]; then
      catkin build ocs2_legged_robot_ros ocs2_self_collision_visualization
    else
      catkin_make \
        -DCMAKE_BUILD_TYPE=RelWithDebInfo \
        -DCATKIN_WHITELIST_PACKAGES="ocs2_legged_robot_ros;ocs2_self_collision_visualization"
    fi
    source devel/setup.bash
  else
    echo "WARN: ocs2_legged_robot_ros is not visible to rospack." >&2
    echo "WARN: If the image does not preinstall OCS2, mount OCS2 sources and rerun with BUILD_OCS2=1." >&2
  fi
fi

if [[ "${BUILD_TOOL}" == "catkin_tools" ]]; then
  catkin build ${BUILD_TARGETS}
else
  catkin_make \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DCATKIN_WHITELIST_PACKAGES="${WHITELIST_PACKAGES}"
fi
'
