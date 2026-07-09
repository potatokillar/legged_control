# ROS2 Migration Notes

本文记录 `legged_control` 后续迁移到 ROS2 的主要事项。当前阶段目标仍是先在 ROS1 Noetic 环境中完成 WL 机器人模型和控制链路的最小验证。

## 当前依赖形态

`legged_control` 不是独立实现 OCS2，而是通过 catkin 依赖外部 OCS2 包：

- `ocs2_legged_robot`
- `ocs2_legged_robot_ros`
- `ocs2_ros_interfaces`
- `ocs2_mpc`
- `ocs2_sqp`
- `ocs2_msgs`
- `ocs2_self_collision`
- `ocs2_self_collision_visualization`

本仓库主要实现：

- 机器人 OCP 问题定义和约束封装：`legged_interface`
- WBC 和 QP 求解封装：`legged_wbc`
- 状态估计：`legged_estimation`
- ROS1 controller 插件：`legged_controllers`
- Gazebo Classic 仿真硬件接口：`legged_gazebo`

## 迁移难点

### OCS2 ROS 接口

现有控制器直接使用 ROS1 风格 OCS2 接口：

- `ocs2_legged_robot_ros/gait/GaitReceiver.h`
- `ocs2_ros_interfaces/synchronized_module/RosReferenceManager.h`
- `ocs2_ros_interfaces/common/RosMsgConversions.h`
- `ocs2_msgs/mpc_observation.h`

迁移到 ROS2 前，需要确认当前 OCS2 版本是否提供等价 ROS2 包。若没有，需要重写 gait command、target trajectories、MPC observation、visualization 和 reference manager 的 ROS 接口层。

### ros-control 到 ros2_control

当前控制器继承 ROS1 `controller_interface::MultiInterfaceController`，并依赖：

- `HybridJointInterface`
- `hardware_interface::ImuSensorInterface`
- `ContactSensorInterface`

ROS2 中需要改为 `ros2_control` 的 `controller_interface::ControllerInterface` 和 lifecycle 流程，并重新声明 state/command interface。若保留 hybrid 命令，需要定义类似：

- `position_desired`
- `velocity_desired`
- `kp`
- `kd`
- `feedforward`

### Gazebo 仿真接口

当前仿真使用 Gazebo Classic + `gazebo_ros_control`：

- URDF 中加载 `liblegged_hw_sim.so`
- `robotSimType` 为 `legged_gazebo/LeggedHWSim`

ROS2 中需要迁移到 `gazebo_ros2_control` 或新的 Gazebo Sim 控制插件，并将 `LeggedHWSim` 的职责改写为 ROS2 `hardware_interface::SystemInterface`。

### 参数、launch 和插件系统

ROS1 的 `roslaunch`、全局参数、`ros::NodeHandle`、controller manager 和 pluginlib 用法都需要迁移：

- launch XML -> ROS2 launch Python/XML
- `rosparam` -> node parameters
- `ros::NodeHandle` -> `rclcpp::Node`
- ROS1 controller manager -> ROS2 controller manager
- ROS1 messages/services -> ROS2 interface packages

## 相对容易复用的部分

以下模块主要是 C++ 数学和模型逻辑，迁移风险相对低：

- `legged_wbc`
- `LeggedRobotPreComputation`
- `SwingTrajectoryPlanner`
- `FrictionConeConstraint`
- `ZeroForceConstraint`
- Kalman filter 数学部分

这些模块仍会依赖 OCS2、Pinocchio 和 Eigen，但不强绑定 ROS1 runtime。

## 建议路线

1. 先用 ROS1 Noetic Docker 编译并运行 WL 仿真，验证 URDF、关节名、足端名、transmission、Gazebo 插件和 `config/wl`。
2. 确认 OCS2 版本和依赖栈，评估是否已有可用 ROS2 分支。
3. 若必须迁移 ROS2，先新建分支，不在当前 ROS1 验证线上直接改。
4. 迁移顺序建议：
   - `legged_wl_description` 的 URDF 和 ros2_control 标签
   - ROS2 hardware interface
   - WBC 纯 C++ 模块
   - 状态估计和 target publisher
   - OCS2 ROS2 接口或替代接口
   - controller lifecycle 和 launch

## ROS1 Docker 验证

当前仓库提供 `docker/ros1/Dockerfile`，基于原始镜像构建本项目的 ROS1 编译镜像：

```bash
docker build -f docker/ros1/Dockerfile -t legged-control-ros1:latest docker/ros1
```

该镜像基于：

```bash
192.168.1.93/iiri/build_x86_arm_ros1:latest
```

派生镜像补充了：

- 过期 ROS apt key 刷新
- `python3-catkin-tools`
- `/home/root` 目录，避免原 entrypoint 在默认 root 用户下报错

`scripts/docker_build_ros1.sh` 默认使用 `legged-control-ros1:latest`，会把 `legged_control_sim` 挂载进容器，在容器中创建 catkin workspace，并默认编译：

```bash
legged_wl_description legged_controllers legged_gazebo
```

脚本优先使用 `catkin build`；如果镜像没有 `catkin-tools`，会自动回退到 `catkin_make` 并使用 `CATKIN_WHITELIST_PACKAGES` 限定目标包。脚本还会在 `catkin_make` 和 `catkin build` 生成目录混用时自动清理 `build/devel/logs`。

已验证的最小 smoke test：

```bash
BUILD_TARGETS=legged_wl_description scripts/docker_build_ros1.sh
```

该命令可以通过，用于确认 WL description 包、URDF 资源挂载和 ROS1 基础环境。

若只验证 Gazebo world 和 WL 模型 spawn，不加载完整控制器，可编译：

```bash
BUILD_TARGETS="legged_wl_description legged_gazebo" scripts/docker_build_ros1.sh
```

启动脚本：

```bash
scripts/docker_launch_ros1.sh gazebo
```

常用参数：

```bash
scripts/docker_launch_ros1.sh gazebo -- gui:=false
scripts/docker_launch_ros1.sh gazebo -- paused:=true z:=0.7
```

完整控制器入口：

```bash
scripts/docker_launch_ros1.sh controller
```

该入口需要完整控制链路编译通过。

默认控制链路目标当前会失败在外部依赖缺失：

- `ocs2_legged_robot`
- `ocs2_legged_robot_ros`
- `ocs2_self_collision`
- `pinocchio`

派生镜像内已确认存在：

- `gazebo_ros_control`
- `controller_interface`
- `hardware_interface`
- `catkin-tools`

如果容器内没有预装 OCS2，需要将 OCS2、Pinocchio、hpp-fcl、ocs2_robotic_assets 放在 `legged_control_sim` 同级可挂载路径下，或通过 `EXTRA_SOURCE_DIRS` 指定。
