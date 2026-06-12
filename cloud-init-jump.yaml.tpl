#cloud-config
package_update: true
packages:
  - curl
  - jq
  - openssh-client

runcmd:
  - echo "TechSprint jump host ready for SSH fan-out." > /etc/motd
  - chown ${admin_username}:${admin_username} /home/${admin_username}

