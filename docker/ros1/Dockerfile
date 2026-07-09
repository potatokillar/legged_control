FROM 192.168.1.93/iiri/build_x86_arm_ros1:latest

ENV DEBIAN_FRONTEND=noninteractive
ENV ROS_MASTER_URI=http://localhost:11311

RUN mkdir -p /home/root \
    && touch /home/root/.bashrc \
    && chown -R root:root /home/root

RUN python3 -c "import urllib.request; print(urllib.request.urlopen('https://raw.githubusercontent.com/ros/rosdistro/master/ros.asc', timeout=30).read().decode(), end='')" \
        | gpg --batch --yes --dearmor -o /usr/share/keyrings/ros1-latest-archive-keyring.gpg

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        python3-catkin-tools \
    && rm -rf /var/lib/apt/lists/*

RUN grep -qxF "source /opt/ros/noetic/setup.bash" /root/.bashrc \
    || echo "source /opt/ros/noetic/setup.bash" >> /root/.bashrc
