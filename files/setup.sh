#!/bin/sh

# Ensure script run as root
if [ "$(id -u)" -ne 0 ]; then
   echo -e "\033[0;31mThis script can be executed only as root. Exiting..."
   exit 1
fi

# Set color variables
R='\033[0;31m' # Red
G='\033[0;32m' # Green

# Initialize variables
username=""
upass=""

# Enter and verify UOL account using Kerberos
while true; do
    echo -e "${G}Verify username and password using Kerberos"
    read -p "Enter UOL username: " username
    echo
    read -s -p "Enter UOL password: " upass

    # Use kinit to obtain a Kerberos ticket
    kinit "$username" <<< "$upass"

    if [ $? -eq 0 ]; then
        echo -e "${G}Kerberos authentication successful."
        break
    else
        echo -e "${R}Kerberos authentication failed. Please check your username and password and try again."
    fi
done

# Enter and verify LUKS passphrase
read -s -p "Enter LUKS Passphrase: " pass
while true; do
    if cryptsetup luksOpen --test-passphrase /dev/nvme0n1p3 luks_temp <<< "$pass"; then
        cryptsetup luksClose luks_temp
        echo -e "${G}LUKS Password Correct, configuring CLEVIS Bind."
        break
    else
        echo -e "${R}LUKS Passphrase incorrect, please enter it again."
    fi
done

# Install clevis
echo -e "${G}Installing Dependencies"
dnf -y install clevis-luks clevis-dracut python36 || echo -e "${R}Error installing Clevis dependencies."

# Install TPM2.0 Clevis Bind
echo -e "${G}Binding to TPM..."
clevis luks bind -d /dev/nvme0n1p3 tpm2 '{"hash":"sha256","key":"rsa","pcr_bank":"sha256","pcr_ids":"7"}' || echo -e "${R}Error binding to TPM."
dracut -fv --regenerate-all || echo -e "${R}Error regenerating initramfs."
echo -e "${G}Set Backup Passphrase"
cryptsetup luksAddKey /dev/nvme0n1p3 luks_temp <<< "$pass"

# Move local home, create symlink, and fix potential SELinux issue
echo -e "${G}Setting /localhome"
mv /home /localhome
semanage fcontext -a -e /home /localhome/home
restorecon -R /localhome/home
ln -s /localhome/home /home
mkdir /localhome/data
chmod 1777 /localhome/data/
ls -Z /localhome
ls -la /localhome/data || echo -e "${R}Error listing /localhome/data."

# Disable Wayland
echo -e "${G}Disabling Wayland"

# Path to the gdm custom.conf file
gdm_conf="/etc/gdm/custom.conf"

# Line to search for in the file
search_line="#WaylandEnable=false"

# Replacement line
replacement_line="WaylandEnable=false"

# Check if the file exists
if [ ! -f "$gdm_conf" ]; then
    echo -e "${R}Error: $gdm_conf does not exist. Please check the file path."
    exit 1
fi

# Check if the line to be replaced exists in the file
if grep -q "$search_line" "$gdm_conf"; then
    # Replace the line
    sed -i "s/$search_line/$replacement_line/" "$gdm_conf"
    echo -e "${G}Default now Xorg."

    # Restore SELinux context if necessary
    restorecon -v "$gdm_conf"
else
    echo -e "${R}Error: $search_line not found in $gdm_conf. No changes made."
    exit 1
fi


# Bootstrap to Satellite
echo -e "${G}Bootstrapping to AZURE Capsule"

# Bootstrap script download
cd ~
bootstrap_script="bootstrap.py"
bootstrap_url="http://satellite02.leeds.ac.uk/pub/$bootstrap_script"

echo "Downloading bootstrap script..."
if curl --insecure --output "$bootstrap_script" --fail "$bootstrap_url"; then
    echo -e "${G}Bootstrap script downloaded successfully."
else
    echo -e "${R}Error: Failed to download the bootstrap script. Exiting."
    exit 1
fi

# Run bootstrap script
python3 "./$bootstrap_script" -l "$username" --new-capsule --server uol-satellite.leeds.ac.uk temp_user <<< "$upass"
sed -i 's/az-lnx-capprd02/uol-satellite/g' /etc/rhsm/rhsm.conf
subscription-manager refresh
echo -e "${G}Verify repositories are from Satellite"
subscription-manager repos | grep URL
echo -e "${G}Final Updates"
puppet agent -t && puppet agent -t && puppet agent -t
dnf -y update
echo -e "${G}FINISHED!"
