#!/bin/bash

set -e

# Already installed? Nothing to do (the installer is re-run to add apps).
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    echo "Docker and the compose plugin are already installed — skipping."
    exit 0
fi


# Function to check if the system is Debian-based
is_debian_based() {
    [ -f /etc/debian_version ]
}

# Function to check if the system is RHEL-based
is_rhel_based() {
    [ -f /etc/redhat-release ]
}

# Function to install Docker on Debian-based systems
install_docker_debian() {
    # Update the apt package index
    sudo apt-get update

    # Install packages to allow apt to use a repository over HTTPS
    sudo apt-get install -y ca-certificates curl

    # Add Docker's official GPG key
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg

    # Set up the stable repository
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    # Update the apt package index again
    sudo apt-get update

    # Install the latest version of Docker CE
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

    # Add the current user to the docker group
    sudo usermod -aG docker "$USER"
}

# Function to install Docker on RHEL-based systems
install_docker_rhel() {
    # Remove old versions of Docker
    sudo yum remove -y docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine

    # Install required packages
    sudo yum install -y yum-utils device-mapper-persistent-data lvm2

    # Add Docker repository
    sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo

    # Install Docker CE
    sudo yum install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

    # Start and enable Docker service
    sudo systemctl start docker
    sudo systemctl enable docker

    # Add the current user to the docker group
    sudo usermod -aG docker "$USER"
}

# Main script execution
if is_debian_based; then
    echo "Detected Debian-based system. Installing Docker for Ubuntu/Debian..."
    install_docker_debian
elif is_rhel_based; then
    echo "Detected RHEL-based system. Installing Docker for RHEL/CentOS..."
    install_docker_rhel
else
    echo "Unsupported operating system. This script only works on Debian-based or RHEL-based systems."
    exit 1
fi

echo "Docker installation completed. You may need to log out and log back in for group changes to take effect."
