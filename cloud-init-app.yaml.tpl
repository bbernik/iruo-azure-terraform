#cloud-config
package_update: true
packages:
  - curl
  - ca-certificates
  - cifs-utils
  - gnupg

write_files:
  - path: /opt/techsprint/instance.env
    permissions: "0600"
    owner: root:root
    content: |
      INSTANCE_NAME=${instance_name}
      STORAGE_ACCOUNT=${storage_account_name}
      FILE_SHARE=${file_share_name}
      BLOB_CONTAINER=${blob_container_name}
  - path: /opt/techsprint/install.sh
    permissions: "0755"
    owner: root:root
    content: |
      #!/usr/bin/env bash
      set -euxo pipefail

      export DEBIAN_FRONTEND=noninteractive

      mkdir -p /data /mnt/azurefiles /opt/moodle

      # --- Optional swap so the first-time Moodle install never gets OOM-killed ---
      if [ ! -f /swapfile ]; then
        fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile
        grep -q "/swapfile" /etc/fstab || echo "/swapfile none swap sw 0 0" >> /etc/fstab
      fi

      # --- Data disk (LUN 0) mounted at /data ---
      DATA_DISK="/dev/disk/azure/scsi1/lun0"
      if [ -b "$DATA_DISK" ] && ! blkid "$DATA_DISK"; then
        mkfs.ext4 -F "$DATA_DISK"
      fi
      if [ -b "$DATA_DISK" ] && ! grep -q " /data " /etc/fstab; then
        echo "$DATA_DISK /data ext4 defaults,nofail 0 2" >> /etc/fstab
        mount /data
      fi

      # --- Azure Files (SMB) mounted at /mnt/azurefiles ---
      if ! grep -q "/mnt/azurefiles" /etc/fstab; then
        mkdir -p /etc/smbcredentials
        cat > /etc/smbcredentials/${storage_account_name}.cred <<'CREDS'
      username=${storage_account_name}
      password=${storage_account_key}
      CREDS
        chmod 600 /etc/smbcredentials/${storage_account_name}.cred
        echo "//${storage_account_name}.file.core.windows.net/${file_share_name} /mnt/azurefiles cifs nofail,credentials=/etc/smbcredentials/${storage_account_name}.cred,dir_mode=0770,file_mode=0660,serverino,nosharesock,actimeo=30" >> /etc/fstab
        mount /mnt/azurefiles || true
      fi

      # --- Install Docker engine + compose v2 ---
      if command -v apt-get >/dev/null 2>&1; then
        apt-get update
        apt-get install -y ca-certificates curl gnupg
        install -m 0755 -d /etc/apt/keyrings
        if [ ! -f /etc/apt/keyrings/docker.asc ]; then
          curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
          chmod a+r /etc/apt/keyrings/docker.asc
        fi
        . /etc/os-release
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $${VERSION_CODENAME} stable" > /etc/apt/sources.list.d/docker.list
        apt-get update
        # Prefer Docker's official packages; fall back to Ubuntu's if the repo is unreachable.
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin \
          || apt-get install -y docker.io docker-compose-v2 \
          || apt-get install -y docker.io docker-compose
        systemctl enable --now docker
      elif command -v dnf >/dev/null 2>&1; then
        dnf install -y dnf-plugins-core
        dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo || true
        dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin || dnf install -y podman podman-compose
        systemctl enable --now docker || true
      fi

      # --- Persisted data dirs owned by the Bitnami runtime user (uid/gid 1001) ---
      # Without this, the non-root containers cannot write to the host bind mounts
      # and crash-loop on startup.
      mkdir -p /data/mariadb /data/moodle
      chown -R 1001:1001 /data/mariadb /data/moodle

      cat > /opt/moodle/docker-compose.yml <<'COMPOSE'
      services:
        mariadb:
          image: docker.io/bitnamilegacy/mariadb:11.4
          restart: unless-stopped
          environment:
            - MARIADB_ROOT_PASSWORD=Moodle_Root_Pass_123
            - MARIADB_USER=bn_moodle
            - MARIADB_PASSWORD=Moodle_Db_Pass_123
            - MARIADB_DATABASE=bitnami_moodle
            - MARIADB_CHARACTER_SET=utf8mb4
            - MARIADB_COLLATE=utf8mb4_unicode_ci
          volumes:
            - /data/mariadb:/bitnami/mariadb
          healthcheck:
            test: ["CMD-SHELL", "mysqladmin ping -uroot -pMoodle_Root_Pass_123 --silent"]
            interval: 15s
            timeout: 10s
            retries: 20
            start_period: 60s
        moodle:
          image: docker.io/bitnamilegacy/moodle:4.5
          restart: unless-stopped
          ports:
            - "80:8080"
          environment:
            - MOODLE_DATABASE_TYPE=mariadb
            - MOODLE_DATABASE_HOST=mariadb
            - MOODLE_DATABASE_PORT_NUMBER=3306
            - MOODLE_DATABASE_USER=bn_moodle
            - MOODLE_DATABASE_PASSWORD=Moodle_Db_Pass_123
            - MOODLE_DATABASE_NAME=bitnami_moodle
            - MOODLE_USERNAME=admin
            - MOODLE_PASSWORD=Moodle_Admin_123
            - MOODLE_EMAIL=admin@example.com
          volumes:
            - /data/moodle:/bitnami/moodle
            - /mnt/azurefiles:/mnt/azurefiles
          depends_on:
            mariadb:
              condition: service_healthy
      COMPOSE

      # --- Bring up the stack (handle both compose v2 plugin and legacy binary) ---
      if docker compose version >/dev/null 2>&1; then
        docker compose -f /opt/moodle/docker-compose.yml up -d
      elif command -v docker-compose >/dev/null 2>&1; then
        docker-compose -f /opt/moodle/docker-compose.yml up -d
      fi

      mkdir -p /var/www/html
      cat > /var/www/html/index.html <<HTML
      <html><body><h1>TechSprint Moodle node</h1><p>${instance_name}</p></body></html>
      HTML

runcmd:
  - /opt/techsprint/install.sh
