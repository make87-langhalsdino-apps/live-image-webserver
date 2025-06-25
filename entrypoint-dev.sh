#!/bin/bash

# Give permissions to use the /tmp directory. Required for pip package installs
sudo chmod 1777 /tmp

# Create make87 keys
ssh-keygen -t ed25519 -C "app@make87.com" -f "/root/.ssh/id_ed25519" -N ""

# copy over the mounted authorized_keys file to the root user's .ssh directory
if [ -f "/root/.ssh/authorized_keys_src" ]; then
  cp /root/.ssh/authorized_keys_src /root/.ssh/authorized_keys
  chown root:root /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
fi

# Start the SSH service
sudo service ssh start

# Set up Git config
git config --global user.email "make87"
git config --global user.name "todo@make87.com"

# Check if the activate script exists, and recreate the venv if needed
if [ ! -f "/home/state/venv/bin/activate" ]; then
    echo "Virtual environment is incomplete or missing. Recreating..."
    python3 -m venv /home/state/venv
    if [ $? -ne 0 ]; then
        echo "Error: Failed to create the virtual environment."
        exit 1
    fi

    echo "Upgrading pip in the virtual environment..."
    /home/state/venv/bin/python3 -m pip install --upgrade pip
    if [ $? -ne 0 ]; then
        echo "Error: Failed to upgrade pip."
        exit 1
    fi
else
    echo "Virtual environment is already complete at /home/state/venv."
fi

# Source the virtual environment
source /home/state/venv/bin/activate
if [ $? -ne 0 ]; then
    echo "Error: Failed to activate the virtual environment."
    exit 1
fi

# Define the target directory for the repository
TARGET_DIR="/home/state/code"

if [ -n "$GIT_URL" ]; then
    # Check if the target directory exists
    if [ ! -d "$TARGET_DIR" ]; then
        # Clone the repository if the directory does not exist
        git clone "$GIT_URL" "$TARGET_DIR"
        cd "$TARGET_DIR" || exit 1

        # Checkout the specified branch if provided
        if [ -n "$GIT_BRANCH" ]; then
            git checkout "$GIT_BRANCH"
        fi
    else
        # Change to the target directory
        cd "$TARGET_DIR" || exit 1

        # Ensure the correct remote URL is set with credentials
        git remote set-url origin "$GIT_URL"

        # Check if the specified branch is provided and switch if needed
        if [ -n "$GIT_BRANCH" ]; then
            CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
            if [ "$CURRENT_BRANCH" != "$GIT_BRANCH" ]; then
                # Stage and commit any changes in the current branch
                git add .
                git commit -m "Saving changes before switching branch" || echo "No changes to commit"

                # Push committed changes using the URL with credentials
                git push origin "$CURRENT_BRANCH" || echo "Failed to push changes"

                # Switch to the target branch
                git checkout "$GIT_BRANCH"
            fi
        fi

        # Pull the latest changes using the URL with credentials
        git pull origin "$GIT_BRANCH" || echo "Failed to pull latest changes"
    fi
fi

# if .vscode dir does not exit create it and add config files
if [ ! -d /home/state/code/.vscode ]; then
  mkdir /home/state/code/.vscode/
  # Create settings.json with the Python interpreter path
  cat <<EOF > /home/state/code/.vscode/settings.json
{
    "python.pythonPath": "/home/state/venv/bin/python"
}
EOF

  # Create launch.json to set up the run configuration with the virtual environment
  cat <<EOF > /home/state/code/.vscode/launch.json
{
    "version": "0.2.0",
    "configurations": [
        {
            "name": "Python: Run Current File",
            "type": "python",
            "request": "launch",
            "program": "\${file}",
            "console": "integratedTerminal",
            "env": {
                "PYTHONPATH": "/home/state/venv/lib/python3.11/site-packages"
            },
            "python": "/home/state/venv/bin/python"
        }
    ]
}
EOF
fi

source /home/state/venv/bin/activate

# check RUN_MODE env var if its ide, ssh or run
DEV_RUN_MODE=${DEV_RUN_MODE:-ide}
if [ "$DEV_RUN_MODE" = "ssh" ]; then
    # SSH server is already running. Keep the container running
    tail -f /dev/null
else
    # pip install, then run /home/state/code/app/main.py
    cd /home/state/code || exit 1

    # if you’ve dropped a pip.conf here, point pip at it
    if [ -f pip.conf ]; then
      echo "Found pip.conf, using it for installation"
      export PIP_CONFIG_FILE="$(pwd)/pip.conf"
    else
      echo "No pip.conf found, installing against default index"
    fi

    pip install -e .
    python -u app/main.py
fi