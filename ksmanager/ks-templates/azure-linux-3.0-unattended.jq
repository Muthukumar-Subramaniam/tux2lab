((.SystemConfigs | map(select(.Name == "Azure Linux Full")) | first) // .SystemConfigs[0]) as $base
| {
    Disks: [
        {
            PartitionTableType: "gpt",
            TargetDisk: {
                Type: "path",
                Value: $disk
            },
            Partitions: [
                {
                    ID: "boot",
                    Type: "esp",
                    Flags: ["esp", "boot"],
                    Start: 1,
                    End: 601,
                    FsType: "fat32"
                },
                {
                    ID: "rootfs",
                    Type: "linux",
                    Start: 601,
                    End: 0,
                    FsType: "ext4"
                }
            ]
        }
    ],
    SystemConfigs: [
        $base + {
            IsDefault: true,
            IsKickStartBoot: false,
            IsIsoInstall: false,
            BootType: "efi",
            EnableGrubMkconfig: true,
            Hostname: $hostname,
            Packages: (($base.Packages // []) + [
                "ca-certificates",
                "curl",
                "openssh-server",
                "rsync",
                "sudo",
                "systemd-networkd",
                "systemd-resolved"
            ] | unique),
            PartitionSettings: [
                {
                    ID: "boot",
                    MountPoint: "/boot/efi",
                    MountOptions: "umask=0077,nodev"
                },
                {
                    ID: "rootfs",
                    MountPoint: "/"
                }
            ],
            Users: [
                {
                    Name: "root",
                    Password: $password_hash,
                    PasswordHashed: true,
                    PasswordExpiresDays: 99999
                },
                {
                    Name: $username,
                    Password: $password_hash,
                    PasswordHashed: true,
                    PasswordExpiresDays: 99999,
                    SecondaryGroups: ["wheel"]
                }
            ],
            PostInstallScripts: (($base.PostInstallScripts // []) + [
                {
                    Path: $post_install_script,
                    Args: ""
                }
            ])
        }
    ]
}
