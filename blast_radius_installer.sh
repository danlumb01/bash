#!/bin/bash 
# Install Blast-Radius for visualising AWS configurations in Terraform
# Assume root user is running!

# Works on Ubuntu 16.04 

# Install pre-reqs
/usr/bin/apt update && /usr/bin/apt install software-properties-common -y && add-apt-repository ppa:deadsnakes/ppa -y
/usr/bin/apt install python3.7 -y

# Install pip for python 3.x
/usr/bin/apt install python3-pip -y

# Upgrade the pip python module (Not the system package!!!)
python3 -m pip install --user --upgrade pip
python3 -m pip install blastradius

