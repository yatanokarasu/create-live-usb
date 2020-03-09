#!/bin/bash


# Exit if there is an unbound variable or an error
set -o nounset
set -o errexit


# Defaults
readonly ALIGNMENT=2048
readonly SECTOR_SIZE=4096

want_to_share=0
shared_part_num=0
shared_part_size=0


# Commands
readonly CMD_CD=$(command -v cd)
readonly CMD_CP=$(command -v cp)
readonly CMD_CAT=$(command -v cat)
readonly CMD_PWD=$(command -v pwd)
readonly CMD_MKDIR=$(command -v mkdir)
readonly CMD_RMDIR=$(command -v rmdir)
readonly CMD_MKTEMP=$(command -v mktemp)

readonly CMD_BASENAME=$(command -v basename)
readonly CMD_DIRNAME=$(command -v dirname)

readonly CMD_WIPEFS=$(command -v wipefs)
readonly CMD_MKFS=$(command -v mkfs)

readonly CMD_MOUNT=$(command -v mount)
readonly CMD_UMOUNT=$(command -v umount)

readonly CMD_GDISK=$(command -v gdisk)
readonly CMD_SGDISK=$(command -v sgdisk)
readonly CMD_GRUB_INSTALL=$(
    command -v grub2-install ||
    command -v grub-install  ||
    { echo "Not found 'grub-install' command. Please install it."; exit 255; }
)

readonly CMD_LSBLK=$(command -v lsblk)
readonly CMD_HEAD=$(command -v head)
readonly CMD_CHOWN=$(command -v chown)

readonly CMD_SUDO=$(command -v sudo)


# Variables
readonly ORIGINAL_USER=${SUDO_USER-$(who -m | awk '{print $1}')}
readonly SCRIPT_DIR=$(${CMD_CD} $(${CMD_DIRNAME} ${0}); ${CMD_PWD})
readonly SCRIPT_NAME=$(${CMD_BASENAME} "${0}")

readonly TMP_DIR="${TMPDIR-/tmp}"

# Create temporary directories
readonly EFI_MNT_DIR=$(${CMD_MKTEMP} -p ${TMP_DIR} -d efi.XXXXX)
readonly IMG_MNT_DIR=$(${CMD_MKTEMP} -p ${TMP_DIR} -d img.XXXXX)



#===============================================================================
# Functions
#===============================================================================

# Show usage
Usage() {
    ${CMD_CAT} <<-__USAGE__
	Usage:
	    ${SCRIPT_NAME} [options] device
	
	This script to prepare Live USB drive
	
	Options:
	    -s, --shared-size       Shared parition size as giga byte unit (e.g. 5 = 5GB)
	__USAGE__
}

# Make sure USB device is not mounted
UnmountDevice() {
    for dev in ${1}*; do ${CMD_UMOUNT} -f ${dev} 2>/dev/null || true; done
}


# Clean up when exiting
CleanUp() {
    # Unmount everything
    ${CMD_UMOUNT} -f ${EFI_MNT_DIR} 2>/dev/null || true
    ${CMD_UMOUNT} -f ${IMG_MNT_DIR} 2>/dev/null || true

    # Delete mountpoints
    [ -d ${EFI_MNT_DIR} ] && ${CMD_RMDIR} ${EFI_MNT_DIR}
    [ -d ${IMG_MNT_DIR} ] && ${CMD_RMDIR} ${IMG_MNT_DIR}

    # Exit
    exit ${1-0}
}

# Trap kill signals (SIGhUP, SIGINT, SIGTERM) to do some cleanup and exit
trap 'CleanUp' 1 2 15



#===============================================================================
# Preparation
#===============================================================================

# Show usage and exit before checking for root
[ "$#" -eq 0 ] && Usage && exit 0

# Check for root
if [ "$(id -u)" -ne 0 ]; then
    printf 'This script MUST be run as root. Using sudo...\n' "${SCRIPT_NAME}" >&2
    exec ${CMD_SUDO} -k -- /bin/sh "${0}" "$@" || CleanUp 2
fi

# Parse arguments
while [ "$#" -gt 0 ]; do
    case "$1" in
        -s|--shared-size)
            shift
            case "$1" in
                [0-9]*)
                    shared_part_size="${1}"
                    ;;
                *)
                    printf '%s: %s is not a valid partition size\n' "${SCRIPT_NAME}" "${1}" >&2
                    CleanUp 1
                    ;;
            esac
            want_to_share=1
            shared_part_num=1
            ;;
        /dev/*)
            if [ -b "${1}" ]; then
                usb_device="${1}"
            else
                printf '%s: %s is not a valid device.\n' "${SCRIPT_NAME}" "${1}" >&2
                CleanUp 1
            fi
            ;;
        *)
            printf '%s: %s is not a valid argument.\n' "${SCRIPT_NAME}" "${1}" >&2
            CleanUp 1
            ;;
    esac

    shift
done

# Check for required arguments
if [ ! "${usb_device}" ]; then
    printf '%s: No device was provided.\n' "${SCRIPT_NAME}" >&2
    Usage
    CleanUp 1
fi

# Device size check
device_size=$(( $(${CMD_LSBLK} ${usb_device} -b -o SIZE -n | ${CMD_HEAD} -n 1) / 1024 / 1024 / 1024 ))
available_size=$(( ${device_size} - 5 ))

if [ "${shared_part_size}" -gt "${available_size}" ]; then
    printf '%s: No enough space for shared partition on your device.\nAvailable size is less than or equal to %sG.\n' "${SCRIPT_NAME}" "${available_size}" >&2
    CleanUp 1
fi

# Determine partition number
bios_part_num=$( expr ${shared_part_num} + 1 )
efi_part_num=$(  expr ${bios_part_num}   + 1 )
img_part_num=$(  expr ${efi_part_num}    + 1 )

# Unmount device
UnmountDevice ${usb_device}

# Confirm the device
printf 'Are you sure you want to use %s? [y/N] ' "${usb_device}"
read -r answer
case ${answer} in
    [yY][eE][sS]|[yY])
        printf 'THIS WILL DELETE ALL DATA ON THE DEVICE. Are you sure? [y/N] '
        read -r final_answer
        case ${final_answer} in
            [yY][eE][sS]|[yY])
                true
                ;;
            *)
                CleanUp 3
                ;;
        esac
        ;;
    *)
        CleanUp 3
        ;;
esac



#===============================================================================
# Main procedure
#===============================================================================

# Print all steps
set -o verbose -o xtrace

#-----------------------------
# Create partitions
#-----------------------------

### purge all partition information
${CMD_SGDISK} --zap-all ${usb_device}

### Create GUID Partition Table
${CMD_SGDISK} --mbrtogpt ${usb_device} || CleanUp 10

### Create partition shared with Windows if you want
if [ "${want_to_share}" -eq 1 ]; then
    ${CMD_SGDISK} \
        --set-alignment ${ALIGNMENT} \
        --new           ${shared_part_num}::+${shared_part_size}G \
        --typecode      ${shared_part_num}:0700 \
        --change-name   ${shared_part_num}:"Shared" \
        ${usb_device} || CleanUp 10
fi

### Create BIOS boot partition (1MB fixed)
${CMD_SGDISK} \
    --set-alignment ${ALIGNMENT} \
    --new           ${bios_part_num}::+1M \
    --typecode      ${bios_part_num}:ef02 \
    --change-name   ${bios_part_num}:"BIOS" \
    ${usb_device} || CleanUp 10

### Create EFI System partition (50MB fixed)
${CMD_SGDISK} \
    --set-alignment ${ALIGNMENT} \
    --new           ${efi_part_num}::+50M \
    --typecode      ${efi_part_num}:ef00 \
    --change-name   ${efi_part_num}:"EFI System" \
    ${usb_device} || CleanUp 10

### Create Data partition
${CMD_SGDISK} \
    --set-alignment ${ALIGNMENT} \
    --new           ${img_part_num}::${image_part_size-} \
    --typecode      ${img_part_num}:8300 \
    --change-name   ${img_part_num}:"Linux filesystem" \
    ${usb_device} || CleanUp 10

UnmountDevice ${usb_device}


#-----------------------------
# Create Hybrid MBR
#-----------------------------

### Create Hybrid MBR
${CMD_CAT} <<__HYBRID__ | ${CMD_GDISK} ${usb_device}
r
h
${bios_part_num} ${efi_part_num} ${img_part_num}
N

N

N

Y
w
Y
__HYBRID__

UnmountDevice ${usb_device}


#-----------------------------
# Wipe & Create file system
#-----------------------------

### Wipe & create file system
if [ "${want_to_share}" -eq 1 ]]; then
    ${CMD_WIPEFS} --all --force ${usb_device}${shared_part_num} || true
    ${CMD_MKFS} -t exfat -s ${SECTOR_SIZE} -n "SHARE" ${usb_device}${shared_part_num} || CleanUp 10
fi

${CMD_WIPEFS} --all --force ${usb_device}${bios_part_num} || true

${CMD_WIPEFS} --all --force ${usb_device}${efi_part_num} || true
${CMD_WIPEFS} --all --force ${usb_device}${img_part_num} || true
${CMD_MKFS} -t fat  -F 32 -n EFI    ${usb_device}${efi_part_num} || CleanUp 10
${CMD_MKFS} -t ext4       -L IMAGES ${usb_device}${img_part_num} || CleanUp 10

UnmountDevice ${usb_device}


#-----------------------------
# Instal GRUB
#-----------------------------

### Mount EFI & Image partition to temporary directories
${CMD_MOUNT} ${usb_device}${efi_part_num} ${EFI_MNT_DIR} || CleanUp 10
${CMD_MOUNT} ${usb_device}${img_part_num} ${IMG_MNT_DIR} || CleanUp 10

### Install GRUB for EFI
${CMD_GRUB_INSTALL} \
    --target=x86_64-efi \
    --efi-directory=${EFI_MNT_DIR} \
    --boot-directory=${IMG_MNT_DIR}/boot \
    --removable \
    --recheck || CleanUp 10

### Install GRUB for BIOS
${CMD_GRUB_INSTALL} \
    --target=i386-pc \
    --boot-directory=${IMG_MNT_DIR}/boot \
    --recheck \
    ${usb_device} || CleanUp 10

### Install fallback GRUB
${CMD_GRUB_INSTALL} \
    --force \
    --target=i386-pc \
    --boot-directory=${IMG_MNT_DIR}/boot \
    --recheck \
    ${usb_device}${img_part_num} || true

### Create necessary directories
${CMD_MKDIR} -p ${IMG_MNT_DIR}/boot/isos

### Copy GRUB configurations
${CMD_CP} -r ${SCRIPT_DIR}/grub.cfg ${IMG_MNT_DIR}/boot/grub/
${CMD_CP} -r ${SCRIPT_DIR}/cfg.d/*  ${IMG_MNT_DIR}/boot/isos/

### Change owner
${CMD_CHOWN} -R ${ORIGINAL_USER}:${ORIGINAL_USER} ${IMG_MNT_DIR}/boot/isos


#-----------------------------
# Clean up and exit
#-----------------------------

CleanUp
