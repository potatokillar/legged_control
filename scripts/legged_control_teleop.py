#!/usr/bin/env python3

import select
import sys
import termios
import time
import tty
from pathlib import Path

import rospy
from gazebo_msgs.msg import ModelState
from gazebo_msgs.srv import SetModelState
from geometry_msgs.msg import Twist


MIN_LINEAR_X_SPEED = 0.03
MIN_LINEAR_Y_SPEED = 0.02
MIN_ANGULAR_Z_SPEED = 0.08
RAMP_TIME = 2.0
KEY_REPEAT_CHAIN_TIMEOUT = 0.8
INITIAL_KEY_RELEASE_TIMEOUT = 0.75
REPEATED_KEY_RELEASE_TIMEOUT = 0.20
GAIT_TRANSITION_TIME = 1.0

GAIT_SPEED_LIMITS = {
    "stance": (0.0, 0.0, 0.0),
    "static_walk": (0.12, 0.06, 0.25),
    "trot": (0.25, 0.10, 0.45),
    "standing_trot": (0.18, 0.08, 0.35),
}


class LeggedTeleop:
    def __init__(self):
        self.robot_type = rospy.get_param("~robot_type", "a1")
        self.gait_command_file = Path(
            rospy.get_param("~gait_command_file", "/tmp/legged_gait_input")
        )
        self.velocity_publisher = rospy.Publisher("/cmd_vel", Twist, queue_size=1)
        self.set_model_state = rospy.ServiceProxy(
            "/gazebo/set_model_state", SetModelState
        )
        self.velocity = Twist()
        self.gait = "stance"
        self.motion_enable_time = rospy.Time.now()
        self.last_motion_key = None
        self.motion_key_start_time = 0.0
        self.last_motion_key_time = 0.0
        self.hold_duration = 0.0
        self.motion_key_repeated = False
        self.motion_release_deadline = 0.0

    def publish_gait(self, gait):
        if not self.gait_command_file.exists():
            raise RuntimeError(
                "gait command pipe is missing: {}".format(self.gait_command_file)
            )
        with self.gait_command_file.open("w") as command_pipe:
            command_pipe.write(gait + "\n")
            command_pipe.flush()
        self.gait = gait
        if gait == "stance":
            self.motion_enable_time = rospy.Time.now()
        else:
            self.motion_enable_time = rospy.Time.now() + rospy.Duration(
                GAIT_TRANSITION_TIME
            )

    def stop(self):
        self.velocity = Twist()
        self.last_motion_key = None
        self.hold_duration = 0.0
        self.motion_key_repeated = False
        self.motion_release_deadline = 0.0
        self.velocity_publisher.publish(self.velocity)

    def ramped_speed(self, minimum, maximum, key):
        now = time.monotonic()
        if (
            key != self.last_motion_key
            or now - self.last_motion_key_time > KEY_REPEAT_CHAIN_TIMEOUT
        ):
            self.motion_key_start_time = now
            self.motion_key_repeated = False
        else:
            self.motion_key_repeated = True

        self.last_motion_key = key
        self.last_motion_key_time = now
        self.hold_duration = now - self.motion_key_start_time
        release_timeout = (
            REPEATED_KEY_RELEASE_TIMEOUT
            if self.motion_key_repeated
            else INITIAL_KEY_RELEASE_TIMEOUT
        )
        self.motion_release_deadline = now + release_timeout
        ratio = min(self.hold_duration / RAMP_TIME, 1.0)
        return minimum + (maximum - minimum) * ratio

    def stop_if_key_released(self):
        if (
            self.last_motion_key is not None
            and time.monotonic() >= self.motion_release_deadline
        ):
            self.stop()

    def prepare_motion(self):
        if self.gait == "stance":
            self.stop()
            self.publish_gait("static_walk")

    def reset_standing(self):
        self.stop()
        self.publish_gait("stance")
        rospy.wait_for_service("/gazebo/set_model_state", timeout=5.0)

        state = ModelState()
        state.model_name = self.robot_type
        state.pose.position.z = 0.5
        state.pose.orientation.w = 1.0
        state.reference_frame = "world"
        response = self.set_model_state(state)
        if not response.success:
            raise RuntimeError(response.status_message)

    def handle_key(self, key):
        if key == "w":
            self.prepare_motion()
            max_linear_x, _, _ = GAIT_SPEED_LIMITS[self.gait]
            self.velocity.linear.x = self.ramped_speed(
                MIN_LINEAR_X_SPEED, max_linear_x, key
            )
        elif key == "s":
            self.prepare_motion()
            max_linear_x, _, _ = GAIT_SPEED_LIMITS[self.gait]
            self.velocity.linear.x = -self.ramped_speed(
                MIN_LINEAR_X_SPEED, max_linear_x, key
            )
        elif key == "a":
            self.prepare_motion()
            _, max_linear_y, _ = GAIT_SPEED_LIMITS[self.gait]
            self.velocity.linear.y = self.ramped_speed(
                MIN_LINEAR_Y_SPEED, max_linear_y, key
            )
        elif key == "d":
            self.prepare_motion()
            _, max_linear_y, _ = GAIT_SPEED_LIMITS[self.gait]
            self.velocity.linear.y = -self.ramped_speed(
                MIN_LINEAR_Y_SPEED, max_linear_y, key
            )
        elif key == "q":
            self.prepare_motion()
            _, _, max_angular_z = GAIT_SPEED_LIMITS[self.gait]
            self.velocity.angular.z = self.ramped_speed(
                MIN_ANGULAR_Z_SPEED, max_angular_z, key
            )
        elif key == "e":
            self.prepare_motion()
            _, _, max_angular_z = GAIT_SPEED_LIMITS[self.gait]
            self.velocity.angular.z = -self.ramped_speed(
                MIN_ANGULAR_Z_SPEED, max_angular_z, key
            )
        elif key in (" ", "0"):
            self.stop()
        elif key == "1":
            self.stop()
            self.publish_gait("stance")
        elif key == "2":
            self.stop()
            self.publish_gait("static_walk")
        elif key == "3":
            self.stop()
            self.publish_gait("trot")
        elif key == "4":
            self.stop()
            self.publish_gait("standing_trot")
        elif key == "r":
            self.reset_standing()
        elif key in ("x", "\x03"):
            return False
        return True

    def status(self):
        return (
            "gait={:<13} vx={:+.2f} vy={:+.2f} wz={:+.2f} hold={:.1f}s".format(
                self.gait,
                self.velocity.linear.x,
                self.velocity.linear.y,
                self.velocity.angular.z,
                self.hold_duration,
            )
        )

    def run(self):
        print("Legged control keyboard teleop")
        print("  W/S: forward/backward    A/D: left/right")
        print("  Q/E: turn left/right     Space or 0: stop")
        print("  1: stance  2: static walk  3: trot  4: standing trot")
        print("  R: reset standing pose   X: exit")
        print("Hold a movement key to accelerate; Space stops immediately.")
        print("Releasing the movement key automatically stops the robot.")

        old_settings = termios.tcgetattr(sys.stdin)
        tty.setcbreak(sys.stdin.fileno())
        rate = rospy.Rate(20)
        running = True

        try:
            self.publish_gait("stance")
            while running and not rospy.is_shutdown():
                readable, _, _ = select.select([sys.stdin], [], [], 0.0)
                if readable:
                    running = self.handle_key(sys.stdin.read(1).lower())
                self.stop_if_key_released()
                if rospy.Time.now() >= self.motion_enable_time:
                    self.velocity_publisher.publish(self.velocity)
                else:
                    self.velocity_publisher.publish(Twist())
                sys.stdout.write("\r" + self.status() + "  ")
                sys.stdout.flush()
                rate.sleep()
        except rospy.ROSInterruptException:
            pass
        finally:
            self.stop()
            self.publish_gait("stance")
            termios.tcsetattr(sys.stdin, termios.TCSADRAIN, old_settings)
            print("\nStopped.")


if __name__ == "__main__":
    rospy.init_node("legged_control_keyboard_teleop")
    LeggedTeleop().run()
