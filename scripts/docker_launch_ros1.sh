#!/usr/bin/env bash
set -euo pipefail

IMAGE="${IMAGE:-legged-control-ros1:latest}"
ROS_MASTER_URI="${ROS_MASTER_URI:-http://localhost:11311}"
SKIP_XHOST="${SKIP_XHOST:-0}"
QT_X11_NO_MITSHM="${QT_X11_NO_MITSHM:-1}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SIM_ROOT="$(cd "${REPO_DIR}/.." && pwd)"
HOST_WS="${HOST_WS:-${SIM_ROOT}/.docker_ros1_ws}"

usage() {
  cat <<EOF
Usage: $(basename "$0") <gazebo|controller|shell> [-- roslaunch_args...]

Commands:
  gazebo      Launch Gazebo empty world and spawn the WL model.
  controller  Load WL controllers and OCS2 helper nodes.
  shell       Open a sourced ROS1 shell in the Docker workspace.

Environment:
  IMAGE          Docker image to use. Default: ${IMAGE}
  HOST_WS        Host path for catkin workspace. Default: ${HOST_WS}
  ROS_MASTER_URI ROS master URI. Default: ${ROS_MASTER_URI}
  SKIP_XHOST     Set to 1 to skip xhost setup. Default: ${SKIP_XHOST}

Examples:
  scripts/docker_launch_ros1.sh gazebo
  scripts/docker_launch_ros1.sh gazebo -- gui:=false
  scripts/docker_launch_ros1.sh gazebo -- paused:=true z:=0.7
  scripts/docker_launch_ros1.sh controller
  scripts/docker_launch_ros1.sh shell
EOF
}

if [[ $# -lt 1 ]]; then
  usage >&2
  exit 2
fi

case "$1" in
  -h|--help)
    usage
    exit 0
    ;;
  gazebo|controller|shell)
    MODE="$1"
    shift
    ;;
  *)
    echo "Unknown command: $1" >&2
    usage >&2
    exit 2
    ;;
esac

if [[ "${1:-}" == "--" ]]; then
  shift
fi

if [[ ! -d "${HOST_WS}" ]]; then
  echo "ERROR: Docker catkin workspace does not exist: ${HOST_WS}" >&2
  echo "Run scripts/docker_build_ros1.sh first." >&2
  exit 3
fi

if [[ -n "${DISPLAY:-}" && "${SKIP_XHOST}" != "1" && "${MODE}" != "controller" ]]; then
  if command -v xhost >/dev/null 2>&1; then
    xhost +local:root >/dev/null
  else
    echo "WARN: xhost command not found; Gazebo GUI may not be able to connect to DISPLAY." >&2
  fi
fi

docker_args=(
  --rm
  --entrypoint /bin/bash
  --network host
  --privileged
  -v "${SIM_ROOT}:/workspace/legged_control_sim"
  -v "${HOST_WS}:/workspace/catkin_ws"
  -e "ROS_MASTER_URI=${ROS_MASTER_URI}"
  -e "QT_X11_NO_MITSHM=${QT_X11_NO_MITSHM}"
  -w /workspace/catkin_ws
)

if [[ -n "${DISPLAY:-}" ]]; then
  docker_args+=(-e "DISPLAY=${DISPLAY}")
  if [[ -d /tmp/.X11-unix ]]; then
    docker_args+=(-v /tmp/.X11-unix:/tmp/.X11-unix)
  fi
fi

if [[ -d /dev/dri ]]; then
  docker_args+=(--device /dev/dri)
fi

if [[ -t 0 && -t 1 ]]; then
  docker_args+=(-it)
fi

docker run "${docker_args[@]}" "${IMAGE}" -lc '
set -euo pipefail
mode="$1"
shift

source /opt/ros/noetic/setup.bash
if [[ ! -f devel/setup.bash ]]; then
  echo "ERROR: devel/setup.bash not found. Build the workspace first." >&2
  exit 20
fi
source devel/setup.bash

require_packages() {
  local missing=()
  local package
  for package in "$@"; do
    if ! rospack find "${package}" >/dev/null 2>&1; then
      missing+=("${package}")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "ERROR: missing ROS packages: ${missing[*]}" >&2
    case "${mode}" in
      gazebo)
        echo "Build first: BUILD_TARGETS=\"legged_wl_description legged_gazebo\" scripts/docker_build_ros1.sh" >&2
        ;;
      controller)
        echo "Build first: scripts/docker_build_ros1.sh" >&2
        echo "Current controller build also requires OCS2 and Pinocchio to be available." >&2
        ;;
    esac
    exit 21
  fi
}

case "${mode}" in
  gazebo)
    require_packages legged_wl_description legged_gazebo gazebo_ros
    exec roslaunch legged_wl_description empty_world.launch "$@"
    ;;
  controller)
    require_packages legged_wl_description legged_controllers controller_manager ocs2_legged_robot_ros
    exec roslaunch legged_wl_description load_controller.launch "$@"
    ;;
  shell)
    exec bash -l
    ;;
esac
' _ "${MODE}" "$@"
