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
    pacman -S --noconfirm base-devel devtools git sudo rsync

# Create a build group and user matching the host IDs
RUN groupadd -g "${GID}" "${USERNAME}" && \
    useradd -m -u "${UID}" -g "${GID}" -s /bin/bash "${USERNAME}" && \
    echo "${USERNAME} ALL=(ALL) NOPASSWD: ALL" > "/etc/sudoers.d/${USERNAME}" && \
    chmod 0440 "/etc/sudoers.d/${USERNAME}"

# Pre-configure the base directory for devtools chroots
RUN mkdir -p /var/lib/archbuild && \
    chown -R "${USERNAME}:${USERNAME}" /var/lib/archbuild

USER ${USERNAME}
WORKDIR /workspace

CMD ["/bin/bash"]
