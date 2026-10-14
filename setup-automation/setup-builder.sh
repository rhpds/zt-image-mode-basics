#!/bin/bash
set -x
trap 'echo "FATAL: setup failed at line ${LINENO}" >> /tmp/progress.log; exit 1' ERR

echo "Setup builder for image mode basics lab" > /tmp/progress.log
chmod 666 /tmp/progress.log

# Register and install git before library fetch
dnf -y remove katello-ca-consumer-* 2>/dev/null || true
subscription-manager clean
subscription-manager register --activationkey="${ACTIVATION_KEY}" --org="${ORG_ID}" --force
dnf install -y git podman skopeo

LIBDIR=/tmp/lab-lib-$$
git clone --depth=1 https://github.com/rhel-labs/lab-setup "${LIBDIR}"
. "${LIBDIR}/common.sh"

# --- lab configuration ---
BOOTC_RHEL_VER=10.2
BUILDER_HOST="builder-${GUID}.${DOMAIN}"
sysctl -w net.ipv4.ip_forward=1
# -------------------------

setup_libvirt
echo "Libvirt configured" >> /tmp/progress.log

setup_redhat_registry_auth
pull_private_images "${RH_REGISTRY_AUTHFILE}" root \
  registry.redhat.io/rhel10/rhel-bootc:${BOOTC_RHEL_VER} \
  registry.redhat.io/rhel10/bootc-image-builder:${BOOTC_RHEL_VER}
echo "Base images pulled" >> /tmp/progress.log

setup_ssl_registry "${BUILDER_HOST}"
echo "Registry up at ${BUILDER_HOST}" >> /tmp/progress.log

fetch_setup_files setup-files
mkdir -p /root/etc/sudoers.d /root/etc/security
cp "${SETUP_FILES}/config.json" /root/config.json
cp "${SETUP_FILES}/Containerfile" /root/Containerfile
cp "${SETUP_FILES}/pwquality.conf" /root/etc/security/pwquality.conf
echo "Setup files staged" >> /tmp/progress.log

echo "%wheel  ALL=(ALL)   NOPASSWD: ALL" > /root/etc/sudoers.d/wheel

add_local_host "builder.${GUID}.${DOMAIN}"
add_local_host "${BUILDER_HOST}"
cp /etc/hosts /root/etc/hosts

persist_env_var REGISTRY "${BUILDER_HOST}"

cat <<'EOF' > /root/wait_for_bootc_vm.sh
echo "Waiting for VM 'bootc-vm' to be running..."
VM_READY=false
VM_STATE=""
VM_NAME=bootc-vm
while true; do
    VM_STATE=$(virsh domstate "$VM_NAME" 2>/dev/null)
    if [[ "$VM_STATE" == "running" ]]; then
        VM_READY=true
        break
    fi
    sleep 10
done
echo "Waiting for SSH to be available..."
NODE_READY=false
while true; do
    if ping -c 1 -W 1 ${VM_NAME} &>/dev/null; then
        NODE_READY=true
        break
    fi
    sleep 5
done
ssh core@${VM_NAME}
EOF
chmod u+x /root/wait_for_bootc_vm.sh

cleanup_registry_auth
cleanup_certbot
cleanup_tmpfiles
echo "Builder setup complete" >> /tmp/progress.log
