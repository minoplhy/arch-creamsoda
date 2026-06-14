# Use the official Arch Linux base image
FROM archlinux:latest

# Define build arguments for user and group IDs to match the host system
# This avoids permission conflicts with mounted workspace volumes
ARG UID=1000
ARG GID=1000
ARG USERNAME=builder

# Update the package database and install essential packages:
# - base-devel: Standard Arch compiler tools (gcc, make, etc.)
# - devtools: Clean chroot build tools (mkarchroot, extra-x86_64-build, etc.)
# - git: Needed for version control and submodule checkouts
# - sudo: Required for chroot build commands (systemd-nspawn)
# - rsync: Needed for publishing repository files
RUN pacman -Syu --noconfirm && \
    pacman -S --noconfirm base-devel devtools git sudo rsync less

# Configure Git system-wide to trust all directories (safe.directory)
# This avoids "dubious ownership" errors when mounting workspaces or running via sudo
RUN git config --system safe.directory '*'

# Create a build group and user matching the host IDs (fallback to 1000 if host is root)
RUN ACTUAL_UID="${UID}"; \
    ACTUAL_GID="${GID}"; \
    if [ "${UID}" -eq 0 ]; then ACTUAL_UID=1000; fi; \
    if [ "${GID}" -eq 0 ]; then ACTUAL_GID=1000; fi; \
    (groupadd -g "${ACTUAL_GID}" "${USERNAME}" 2>/dev/null || groupadd "${USERNAME}") && \
    (useradd -m -u "${ACTUAL_UID}" -g "${USERNAME}" -s /bin/bash "${USERNAME}" 2>/dev/null || useradd -m -g "${USERNAME}" -s /bin/bash "${USERNAME}") && \
    echo "${USERNAME} ALL=(ALL) NOPASSWD: ALL" > "/etc/sudoers.d/${USERNAME}" && \
    chmod 0440 "/etc/sudoers.d/${USERNAME}"

# Pre-configure the base directory for devtools chroots and package cache
RUN mkdir -p /var/lib/archbuild /var/cache/sources && \
    chown -R "${USERNAME}:${USERNAME}" /var/lib/archbuild /var/cache/sources && \
    chmod 777 /var/cache/sources && \
    sed -i 's|^#SRCDEST=.*|SRCDEST=/var/cache/sources|' /etc/makepkg.conf && \
    echo 'if [ -f /.dockerenv ]; then export GNUPGHOME="${WORKSPACE_DIR:-/workspace}/.gnupg"; fi' >> /etc/makepkg.conf && \
    if [ -f /usr/share/devtools/makepkg-x86_64.conf ]; then \
        sed -i 's|^#SRCDEST=.*|SRCDEST=/var/cache/sources|' /usr/share/devtools/makepkg-x86_64.conf && \
        echo 'if [ -f /.dockerenv ]; then export GNUPGHOME="${WORKSPACE_DIR:-/workspace}/.gnupg"; fi' >> /usr/share/devtools/makepkg-x86_64.conf; \
    fi

# Install secure wrapper for systemd-nspawn to disable D-Bus/systemd registration when running inside Docker
RUN printf '#!/bin/bash\nexec /usr/bin/systemd-nspawn --register=no --keep-unit "$@"\n' > /usr/local/bin/systemd-nspawn && \
    chown root:root /usr/local/bin/systemd-nspawn && \
    chmod 0755 /usr/local/bin/systemd-nspawn

USER ${USERNAME}
WORKDIR /workspace

CMD ["/bin/bash"]
