# PLACEHOLDER — replace contents of this file with the output of
#   nixos-generate-config --root /mnt --show-hardware-config
# run from the NixOS installer once the laptop's disks are partitioned and
# mounted. Then re-add the btrfs subvol options for @root, @home, @nix,
# @persist, @log to match hosts/diana/hardware.nix.
{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  # TODO: fill in from nixos-generate-config
  boot.initrd.availableKernelModules = [ ];
  boot.initrd.kernelModules = [ ];
  # Most Lenovos are Intel: kvm-intel. AMD Lenovos: kvm-amd.
  boot.kernelModules = [ "kvm-intel" ];
  boot.extraModulePackages = [ ];

  # TODO: replace UUIDs once the laptop is partitioned.
  # Same btrfs subvol layout as Diana: @root, @home, @nix, @persist, @log.
  #
  # fileSystems."/" =
  #   { device = "/dev/disk/by-uuid/REPLACE-ME";
  #     fsType = "btrfs";
  #     options = [ "subvol=@root" ];
  #   };
  #
  # fileSystems."/boot" =
  #   { device = "/dev/disk/by-uuid/REPLACE-ME";
  #     fsType = "vfat";
  #     options = [ "fmask=0077" "dmask=0077" ];
  #   };
  #
  # fileSystems."/home" =
  #   { device = "/dev/disk/by-uuid/REPLACE-ME";
  #     fsType = "btrfs";
  #     options = [ "subvol=@home" ];
  #     neededForBoot = true;
  #   };
  #
  # fileSystems."/nix" =
  #   { device = "/dev/disk/by-uuid/REPLACE-ME";
  #     fsType = "btrfs";
  #     options = [ "subvol=@nix" ];
  #   };
  #
  # fileSystems."/persist" =
  #   { device = "/dev/disk/by-uuid/REPLACE-ME";
  #     fsType = "btrfs";
  #     options = [ "subvol=@persist" ];
  #     neededForBoot = true;
  #   };
  #
  # fileSystems."/var/log" =
  #   { device = "/dev/disk/by-uuid/REPLACE-ME";
  #     fsType = "btrfs";
  #     options = [ "subvol=@log" ];
  #   };

  swapDevices = [ ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  # If this is an AMD Lenovo, change to hardware.cpu.amd.updateMicrocode.
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
