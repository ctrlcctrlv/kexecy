#/bin/bash
#   Copyright 2023 Fredrick R. Brennan <copypaste@kittens.ph>
#
#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
#
#       http://www.apache.org/licenses/LICENSE-2.0
#
#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.
KEXECYTIEM=<<- 'EOF'
                It's
     _                            _ 
    | | _______  _____  ___ _   _| |
    | |/ / _ \ \/ / _ \/ __| | | | |
    |   <  __/>  <  __/ (__| |_| |_|
    |_|\_\___/_/\_\___|\___|\__, (_)
                            |___/   
            t  i  m  e          :-D

    8====================D~~~~~~ MAPACHE WUZ HERE
EOF

# Check if the user is root
maybe_fix_pebkac() {
  # Check if script is already running with sudo
  if [ "$EUID" -eq 0 ]; then
    return
  else
    >&2 echo "You must be r00t !"
  fi

  # Check if sudo command is available
  if ! command -v sudo &> /dev/null; then
    >&2 echo "sudo command not found. Unable to restart with sudo."
    return 1
  fi

  # Check if user has sudo privileges
  if ! sudo -n true 2>/dev/null; then
    >&2 echo "You do not have sudo privileges. Unable to restart with sudo."
    return 1
  fi

  # Restart script with sudo
  >&2 echo "Restarting script with sudo..."
  sudo "$0" "$@"
  exit $?
}


#Check kexecy deps
kexecy_check_deps() {
    local DEPS=(lscpu jq kexec dialog systemctl)
    # pacman -Qo `which lscpu jq kexec dialog systemctl` | grep -Po 'is owned by (.*?) ' | cut -d ' ' -f 4
    local DEPS_PKGS=(util-linux jq kexec-tools dialog systemd)

    for ((i=0; i<${#DEPS_PKGS[@]}; i++)); do
        dep=${DEPS[i]}
        which $dep >/dev/null 2>&1
        if [[ $? -ne 0 ]]; then
            read -p "Do you want to install $dep? [Y/n]: " answer
            if [[ $answer =~ ^[Yy]$ || $answer == "" ]]; then
                pacman -S $dep --noconfirm
                if [[ $? -ne 0 ]]; then
                    exit 2
                fi
            else
                exit 3
            fi
        fi
    done
}

# Check CPU vendor
kexecy_microcode() {
    # Confirm with the user if they want to load microcode
    dialog --clear --title "Load microcode?" --extra-button --extra-label Back --yesno "Do you want to load microcode?" 7 60 
    response=$?
    if [[ $response -eq 0 && -f $microcode_file ]]; then
        vendor=$(lscpu -J|jq -r '.lscpu[]|select(.field == "Vendor ID:").data')
        microcode_file=""
        if [[ "$vendor" == "GenuineIntel" ]]; then
          microcode_file="/boot/intel-ucode.img"
        elif [[ "$vendor" == "AuthenticAMD" ]]; then
          microcode_file="/boot/amd-ucode.img"
        fi
    else
        exit $response
    fi
    return $response
}

# Get a list of available kernels
kexecy_kernels() {
    kernels=$(ls /boot | grep -E 'vmlinuz-linux[-a-zA-Z0-9]*')

    # Create a list for dialog
    kernel_list=""
    count=1
    for kernel in $kernels; do
      kernel_list="$kernel_list $count $kernel"
      count=$((count+1))
    done

    # Get the selected kernel
    selected_kernel=$(echo $kernels | awk -v choice="$kernel_choice" '{print $choice}')
    initrd_file="/boot/initramfs-${selected_kernel#vmlinuz-}.img"
}

# Create a temporary initramfs file
declare -g temp_initrd
kexecy_initramfs() {
    local KEXECY_TMP=/boot/kexecy/initrds
    temp_initrd="/boot/$(date +%Y%m%d_%s)_initramfs.img"
    if [[ -f "$KEXECY_TMP" ]]; then
      while read line; do
        rm "$line" 2> /dev/null;
      done < "$KEXECY_TMP"
    else
      mkdir "$(dirname "$KEXECY_TMP")"
    fi
    cat >> /boot/kexecy/initrds <<< "$temp_initrd\n"
    if [[ $response -eq 0 && -f $microcode_file ]]; then
      # Calculate the required disk space
      required_space=$(du -b $microcode_file $initrd_file | awk '{sum+=$1} END {print sum}')

      # Check for enough disk space in /boot
      available_space=$(df /boot | awk 'NR==2 {print $4 * 1024}') # Convert to bytes

      if [[ $available_space -lt $required_space ]]; then
         >&2 echo "Not enough space in /boot. Required: $required_space bytes. Available: $available_space bytes. Aborting."
         exit 1
      fi

      cat $microcode_file $initrd_file > $temp_initrd
    else
      cp $initrd_file $temp_initrd
    fi
    echo "$temp_initrd"
}

declare -g new_cmdline
kexecy_cmdline() {
    # Get the current command line and replace BOOT_IMAGE
    local current_cmdline="$(cat /proc/cmdline)"
    new_cmdline="$(echo $current_cmdline | sed "s|BOOT_IMAGE=[^ ]*|BOOT_IMAGE=/boot/$selected_kernel|")"
}

kexecy() {
    maybe_fix_pebkac "$@"
    while true; do
      cmd=(dialog --backtitle "Kexecy Configuration" --menu "Choose an option" 22 76 16)
      options=(1 "Select Kernel"
               2 "Microcode options"
               3 "Fallback initramfs"
               4 "Execute kexec"
               5 "Exit")
      choice=$("${cmd[@]}" "${options[@]}" 2>&1 >/dev/tty)
      if [ $? -eq 1 ]; then continue; fi  # User hit 'Cancel' or 'ESC'
      
      case $choice in
        1)
          dialog --clear --title "Select Kernel" --menu "Choose a kernel:" 15 40 6 $kernel_list 2> /tmp/kernel_choice
          if [ $? -eq 0 ]; then
            kernel_choice=$(cat /tmp/kernel_choice)
          fi
          ;;
        2)
          dialog --clear --title "Microcode options" --yesno "Do you want to load microcode?" 7 40
          microcode_choice=$?
          ;;
        3)
          dialog --clear --title "Fallback initramfs" --yesno "Do you want to use fallback initramfs?" 7 40
          initramfs_choice=$?
          ;;
        4)
          # Final confirmation and execute kexec based on choices
          dialog --clear --title "Confirmation" --yesno "Are you sure you want to proceed with these choices?" 7 40
          if [ $? -eq 0 ]; then
            # Call your existing functions to actually execute kexec
            wall "$KEXECYTIEM"
            kexecy_check_deps
            kexecy_kernels
            kexecy_microcode
            kexecy_initramfs
            kexecy_cmdline

            break
          fi
          ;;
        5)
          # Exit
          exit 0
          ;;
      esac
    done


    # Load the selected kernel into kexec
    kexec -l "/boot/$selected_kernel" --initrd="$temp_initrd" --command-line="$new_cmdline"

    # Confirm the action with the user
    dialog --clear --title "Confirmation" --yesno "Are you sure you want to kexec into the selected kernel?" 7 60

    # If the user confirms, execute kexec
    if [[ $? -eq 0 ]]; then
      coproc systemctl kexec
      sleep 5
      for key in r e i s u b; do
          echo -n "$key" > /proc/sysrq-trigger
          sleep 1
      done
    else
      >&2 echo "Kexec aborted by the user."
      rm $temp_initrd
      exit 55
    fi
}

kexecy
