# Shared docker plumbing for kudos's container-based factories. Sourced, not executed.
#
# Docker needs either group membership or root, and which one a given machine offers is
# not something to hardcode. Probe rather than assume, and say so plainly if neither
# works — "permission denied" from the daemon is a confusing way to learn this.
pick_docker() {
    if docker info >/dev/null 2>&1; then
        DOCKER="docker"
    elif sudo -n docker info >/dev/null 2>&1; then
        DOCKER="sudo docker"
    elif command -v docker >/dev/null 2>&1; then
        echo "docker: ERROR: docker is installed but this user cannot reach the daemon." >&2
        echo "  Either: sudo usermod -aG docker $USER   (then log out and back in)" >&2
        echo "  Or run the make target under sudo." >&2
        exit 1
    else
        echo "docker: ERROR: docker is not installed." >&2
        echo "  Debian/Ubuntu: sudo apt-get install -y docker.io" >&2
        exit 1
    fi
}
