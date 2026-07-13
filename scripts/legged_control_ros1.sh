#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
PROJECT_DIR="$(cd -- "${REPOSITORY_DIR}/.." && pwd)"

IMAGE="${LEGGED_IMAGE:-legged-control-ros1:latest}"
CONTAINER="${LEGGED_CONTAINER:-legged-control-ros1}"
ROBOT_TYPE="${ROBOT_TYPE:-a1}"
WORKSPACE_DIR="${LEGGED_WORKSPACE:-${PROJECT_DIR}/.docker_legged_control_ros1_ws}"
GUI_ENABLED="${LEGGED_GUI:-1}"
SOFTWARE_RENDERING="${LEGGED_SOFTWARE_RENDERING:-1}"
HOST_XAUTHORITY="${XAUTHORITY:-${HOME}/.Xauthority}"
CONTAINER_PROJECT_DIR="/workspace/legged_control_sim"
CONTAINER_WORKSPACE="/workspace/catkin_ws"
ROS_SETUP="source /opt/ros/noetic/setup.bash && source ${CONTAINER_WORKSPACE}/devel/setup.bash"

usage() {
  cat <<EOF
Usage: $(basename "$0") <command>

Commands:
  start    Create/reuse the container and start Gazebo and the controllers
  status   Show the container, ROS nodes, model, and controller states
  logs     Show recent Gazebo and controller logs
  gui      Open or reopen the Gazebo GUI
  teleop   Control the robot with the keyboard
  shell    Open a configured shell in the container
  stop     Stop the container

Environment:
  ROBOT_TYPE         Robot model, default: a1
  LEGGED_IMAGE       Docker image, default: legged-control-ros1:latest
  LEGGED_CONTAINER   Container name, default: legged-control-ros1
  LEGGED_WORKSPACE   Built catkin workspace directory
  LEGGED_GUI         Enable Gazebo GUI, default: 1
  LEGGED_SOFTWARE_RENDERING  Use Mesa software rendering, default: 1
EOF
}

die() {
  echo "Error: $*" >&2
  exit 1
}

container_exists() {
  docker container inspect "${CONTAINER}" >/dev/null 2>&1
}

container_running() {
  [[ "$(docker inspect -f '{{.State.Running}}' "${CONTAINER}" 2>/dev/null || true)" == "true" ]]
}

container_exec() {
  docker exec "${CONTAINER}" bash -lc "$1"
}

container_has_gui() {
  container_env="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "${CONTAINER}" 2>/dev/null)"
  grep -qx "DISPLAY=${DISPLAY:-}" <<<"${container_env}" &&
    grep -qx "LIBGL_ALWAYS_SOFTWARE=${SOFTWARE_RENDERING}" <<<"${container_env}" &&
    docker inspect -f '{{range .Mounts}}{{println .Destination}}{{end}}' "${CONTAINER}" 2>/dev/null |
      grep -qx '/tmp/.X11-unix'
}

require_environment() {
  command -v docker >/dev/null 2>&1 || die "docker is not installed"
  docker image inspect "${IMAGE}" >/dev/null 2>&1 || die "image not found: ${IMAGE}"
  [[ -d "${WORKSPACE_DIR}" ]] || die "workspace not found: ${WORKSPACE_DIR}"
  [[ -f "${WORKSPACE_DIR}/devel/.private/catkin_tools_prebuild/setup.bash" ]] ||
    die "workspace is not built: ${WORKSPACE_DIR}"
  if [[ "${GUI_ENABLED}" == "1" ]]; then
    [[ -n "${DISPLAY:-}" ]] || die "DISPLAY is not set; use LEGGED_GUI=0 for headless mode"
    [[ -d /tmp/.X11-unix ]] || die "X11 socket directory not found: /tmp/.X11-unix"
    [[ -f "${HOST_XAUTHORITY}" ]] || die "Xauthority file not found: ${HOST_XAUTHORITY}"
  fi
}

ensure_container() {
  if container_exists && [[ "${GUI_ENABLED}" == "1" ]] && ! container_has_gui; then
    echo "Recreating ${CONTAINER} with X11 access..."
    docker rm -f "${CONTAINER}" >/dev/null
  fi

  if ! container_exists; then
    echo "Creating container ${CONTAINER}..."
    docker_args=(
      run -d
      --name "${CONTAINER}"
      --network host
      --entrypoint /bin/bash
      --cap-add SYS_NICE
      --ulimit rtprio=99
      --ulimit memlock=-1
      -e HOME=/root
      -e "ROBOT_TYPE=${ROBOT_TYPE}"
      -v "${PROJECT_DIR}:${CONTAINER_PROJECT_DIR}"
      -v "${WORKSPACE_DIR}:${CONTAINER_WORKSPACE}"
      -w "${CONTAINER_WORKSPACE}"
    )

    if [[ "${GUI_ENABLED}" == "1" ]]; then
      docker_args+=(
        -e "DISPLAY=${DISPLAY}"
        -e XAUTHORITY=/tmp/legged-control.xauth
        -e QT_X11_NO_MITSHM=1
        -e "LIBGL_ALWAYS_SOFTWARE=${SOFTWARE_RENDERING}"
        -v /tmp/.X11-unix:/tmp/.X11-unix:rw
        -v "${HOST_XAUTHORITY}:/tmp/legged-control.xauth:ro"
      )
      if [[ "${SOFTWARE_RENDERING}" != "1" && -d /dev/dri ]]; then
        docker_args+=(--device /dev/dri:/dev/dri)
      fi
    fi

    docker "${docker_args[@]}" "${IMAGE}" -lc 'sleep infinity' >/dev/null
  elif ! container_running; then
    echo "Starting container ${CONTAINER}..."
    docker start "${CONTAINER}" >/dev/null
  fi
}

wait_for_model() {
  echo "Waiting for the ${ROBOT_TYPE} model..."
  for _ in $(seq 1 45); do
    if container_exec "${ROS_SETUP} && timeout 3 rosservice call /gazebo/get_model_state 'model_name: ${ROBOT_TYPE}' 2>/dev/null" |
      grep -q 'success: True'; then
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_for_controller() {
  echo "Waiting for the controller (first startup may compile CppAD models)..."
  for _ in $(seq 1 120); do
    if container_exec "${ROS_SETUP} && timeout 5 rosservice call /controller_manager/list_controllers 2>/dev/null" |
      grep -q 'controllers/legged_controller'; then
      return 0
    fi
    sleep 1
  done
  return 1
}

show_logs() {
  container_running || die "container is not running: ${CONTAINER}"
  container_exec "echo '--- Gazebo ---'; tail -80 /tmp/legged_gazebo.log 2>/dev/null || true; echo '--- Controller ---'; tail -120 /tmp/legged_controller.log 2>/dev/null || true"
}

show_status() {
  if ! container_running; then
    echo "Container ${CONTAINER}: stopped"
    return 1
  fi

  echo "Container ${CONTAINER}: running"
  if [[ "${GUI_ENABLED}" == "1" ]]; then
    container_exec "if pgrep -x gzclient >/dev/null; then echo 'Gazebo GUI: running'; else echo 'Gazebo GUI: not running'; fi"
  fi
  container_exec "${ROS_SETUP} && echo '--- ROS nodes ---' && rosnode list 2>/dev/null || true"
  container_exec "${ROS_SETUP} && echo '--- Model ---' && timeout 5 rosservice call /gazebo/get_model_state 'model_name: ${ROBOT_TYPE}' 2>/dev/null | grep -E 'success:|status_message:' || true"
  container_exec "${ROS_SETUP} && echo '--- Controllers ---' && timeout 5 rosservice call /controller_manager/list_controllers 2>/dev/null | grep -E 'name:|state:' || true"
}

start_gui() {
  require_environment
  ensure_container
  [[ "${GUI_ENABLED}" == "1" ]] || die "Gazebo GUI is disabled; unset LEGGED_GUI or set it to 1"
  container_exec "${ROS_SETUP} && rosnode list 2>/dev/null | grep -qx /gazebo" ||
    die "Gazebo server is not running; run '$(basename "$0") start' first"

  if container_exec "pgrep -x gzclient >/dev/null"; then
    echo "Gazebo GUI is already running."
    return 0
  fi

  echo "Starting Gazebo GUI..."
  docker exec -d "${CONTAINER}" bash -lc \
    "${ROS_SETUP} && exec rosrun gazebo_ros gzclient > /tmp/legged_gazebo_gui.log 2>&1" \
    >/dev/null 2>&1

  for _ in $(seq 1 15); do
    if container_exec "pgrep -x gzclient >/dev/null"; then
      echo "Gazebo GUI is running."
      return 0
    fi
    sleep 1
  done

  container_exec "tail -80 /tmp/legged_gazebo_gui.log 2>/dev/null || true"
  die "Gazebo GUI failed to start"
}

start_teleop() {
  require_environment
  ensure_container
  container_exec "${ROS_SETUP} && rosservice list 2>/dev/null | grep -qx /controller_manager/list_controllers" ||
    die "controllers are not running; run '$(basename "$0") start' first"

  docker exec -it \
    -e "ROBOT_TYPE=${ROBOT_TYPE}" \
    "${CONTAINER}" bash -lc \
    "${ROS_SETUP} && exec python3 ${CONTAINER_PROJECT_DIR}/legged_control/scripts/legged_control_teleop.py _robot_type:=${ROBOT_TYPE}"
}

start_stack() {
  require_environment
  ensure_container

  if ! container_exec "${ROS_SETUP} && rosnode list 2>/dev/null | grep -qx /gazebo"; then
    echo "Starting Gazebo..."
    docker exec -d "${CONTAINER}" bash -lc \
      "${ROS_SETUP} && export ROBOT_TYPE=${ROBOT_TYPE} && exec roslaunch legged_unitree_description empty_world.launch > /tmp/legged_gazebo.log 2>&1" \
      >/dev/null 2>&1 || true

    if ! wait_for_model; then
      echo "Gazebo failed to load the model." >&2
      show_logs
      exit 1
    fi
  else
    echo "Gazebo is already running."
  fi

  if ! container_exec "${ROS_SETUP} && rosnode list 2>/dev/null | grep -qx /legged_robot_gait_command"; then
    echo "Loading controllers..."
    docker exec -d "${CONTAINER}" bash -lc \
      "${ROS_SETUP} && export ROBOT_TYPE=${ROBOT_TYPE} && rm -f /tmp/legged_gait_input && mkfifo /tmp/legged_gait_input && exec 3<>/tmp/legged_gait_input && roslaunch legged_controllers load_controller.launch cheater:=false <&3 > /tmp/legged_controller.log 2>&1" \
      >/dev/null 2>&1 || true
  else
    echo "Controller nodes are already running."
  fi

  if ! wait_for_controller; then
    echo "The legged controller did not initialize." >&2
    show_logs
    exit 1
  fi

  controller_started=0
  controller_state="$(container_exec "${ROS_SETUP} && timeout 5 rosservice call /controller_manager/list_controllers 2>/dev/null" || true)"
  if ! grep -A1 'name: "controllers/legged_controller"' <<<"${controller_state}" | grep -q 'state: "running"'; then
    echo "Starting controllers..."
    container_exec "${ROS_SETUP} && timeout 30 rosservice call /controller_manager/switch_controller '[controllers/legged_controller, controllers/joint_state_controller]' '[]' 2 false 10.0" |
      grep -q 'ok: True' || die "controller switch failed"
    controller_started=1
  fi

  if [[ "${controller_started}" == "1" ]]; then
    echo "Resetting the robot to the standing pose..."
    container_exec "${ROS_SETUP} && printf 'stance\n' > /tmp/legged_gait_input && rostopic pub -1 /cmd_vel geometry_msgs/Twist '{linear: {x: 0.0, y: 0.0, z: 0.0}, angular: {z: 0.0}}' >/dev/null && rosservice call /gazebo/set_model_state '{model_state: {model_name: ${ROBOT_TYPE}, pose: {position: {x: 0.0, y: 0.0, z: 0.5}, orientation: {x: 0.0, y: 0.0, z: 0.0, w: 1.0}}, twist: {linear: {x: 0.0, y: 0.0, z: 0.0}, angular: {x: 0.0, y: 0.0, z: 0.0}}, reference_frame: world}}' >/dev/null"
  fi

  echo "legged_control is running."
  show_status
}

open_shell() {
  require_environment
  ensure_container
  docker exec -it \
    -e "ROBOT_TYPE=${ROBOT_TYPE}" \
    "${CONTAINER}" bash -lc \
    "${ROS_SETUP} && export ROBOT_TYPE=${ROBOT_TYPE} && exec bash -i"
}

stop_container() {
  if container_running; then
    docker stop "${CONTAINER}" >/dev/null
    echo "Container ${CONTAINER} stopped."
  else
    echo "Container ${CONTAINER} is already stopped."
  fi
}

case "${1:-}" in
  start) start_stack ;;
  status) show_status ;;
  logs) show_logs ;;
  gui) start_gui ;;
  teleop) start_teleop ;;
  shell) open_shell ;;
  stop) stop_container ;;
  -h | --help | help) usage ;;
  *) usage; exit 1 ;;
esac
