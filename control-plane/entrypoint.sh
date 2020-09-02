#!/bin/bash

# This script is copied from:
# https://github.com/jieyu/docker-images/blob/master/dind/entrypoint.sh
# with few adjustment

set -o errexit
set -o nounset
set -o pipefail

# This is copied from official dind script:
# https://raw.githubusercontent.com/docker/docker/master/hack/dind
if [ -d /sys/kernel/security ] && ! mountpoint -q /sys/kernel/security; then
    mount -t securityfs none /sys/kernel/security || {
        echo >&2 'Could not mount /sys/kernel/security.'
        echo >&2 'AppArmor detection and --privileged mode might break.'
    }
fi

# Mount /tmp (conditionally)
if ! mountpoint -q /tmp; then
    mount -t tmpfs none /tmp
fi

# Check cgroupfs.
# TODO(jieyu): Verify the filesystem.
if [ ! -d /sys/fs/cgroup/ ]; then
    echo >&2 'cgroupfs is not mounted'
    exit 1
fi

# Determine cgroup parent for docker daemon.
# We need to make sure cgroups created by the docker daemon do not
# interfere with other cgroups on the host, and do not leak after this
# container is terminated.
if [ -f /sys/fs/cgroup/systemd/release_agent ]; then
    # This means the user has bind mounted host /sys/fs/cgroup to the
    # same location in the container (e.g., using the following docker
    # run flags: `-v /sys/fs/cgroup:/sys/fs/cgroup`). In this case, we
    # need to make sure the docker daemon in the container does not
    # pollute the host cgroups hierarchy.
    # Note that `release_agent` file is only created at the root of a
    # cgroup hierarchy.
    CGROUP_PARENT="$(grep systemd /proc/self/cgroup | cut -d: -f3)/docker"
else
    CGROUP_PARENT="/docker"

    # For each cgroup subsystem, Docker does a bind mount from the
    # current cgroup to the root of the cgroup subsystem. For instance:
    #   /sys/fs/cgroup/memory/docker/<cid> -> /sys/fs/cgroup/memory
    #
    # This will confuse some system software that manipulate cgroups
    # (e.g., kubelet/cadvisor, etc.) sometimes because
    # `/proc/<pid>/cgroup` is not affected by the bind mount. The
    # following is a workaround to recreate the original cgroup
    # environment by doing another bind mount for each subsystem.
    CURRENT_CGROUP=$(grep systemd /proc/self/cgroup | cut -d: -f3)
    CGROUP_SUBSYSTEMS=$(findmnt -lun -o source,target -t cgroup | grep "${CURRENT_CGROUP}" | awk '{print $2}')

    echo "${CGROUP_SUBSYSTEMS}" |
    while IFS= read -r SUBSYSTEM; do
        mkdir -p "${SUBSYSTEM}${CURRENT_CGROUP}"
        mount --bind "${SUBSYSTEM}" "${SUBSYSTEM}${CURRENT_CGROUP}"
    done
fi

mkdir -p /var/log/docker

setsid dockerd \
    --cgroup-parent="${CGROUP_PARENT}" \
    --bip="${DOCKERD_BIP:-172.17.1.1/24}" \
    --mtu="${DOCKERD_MTU:-1400}" \
    --raw-logs \
    ${DOCKER_ARGS:-} >/var/log/docker/dockerd.log 2>&1 &

# Wait until dockerd is ready.
echo -n "Waiting for usable dockerd..."
until docker ps >/dev/null 2>&1
do
    echo -n "."
    sleep 1
done

echo ""
echo "Setting up KIND cluster"

# Startup a KIND cluster.
API_SERVER_ADDRESS=${API_SERVER_ADDRESS:-"127.0.0.1"}
sed -i "s/apiServerAddress:$/apiServerAddress: ${API_SERVER_ADDRESS}/" kind-config.yaml

CERT_SANS=(${CERT_SANS:-""})
CERT_SANS+=(${API_SERVER_ADDRESS})
CERT_SANS+=($(hostname -i))
CERT_SANS+=(localhost)
CERT_SANS+=(127.0.0.1)

UNIQUE_CERT_SANS=($(echo "${CERT_SANS[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' '))

for host in "${UNIQUE_CERT_SANS[@]}"; do
    cat <<EOF>> /kind-config.yaml
- group: kubeadm.k8s.io
  version: v1beta2
  kind: ClusterConfiguration
  patch: |
    - op: add
      path: /apiServer/certSANs/-
      value: ${host}

EOF
done

kind create cluster --config=kind-config.yaml --image=${KIND_NODE_IMAGE:-"antrusd/kink:v1.15.11-1-node"} --wait=900s

exec "$@"
