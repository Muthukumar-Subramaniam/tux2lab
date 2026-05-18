#!/usr/bin/env bash
#----------------------------------------------------------------------------------------#
# Script Name: download-infra-iso.sh                                                     #
# Description: Download and verify the infrastructure server ISO (VM mode only)          #
# If you encounter any issues with this script, or have suggestions or feature requests, #
# please open an issue at: https://github.com/Muthukumar-Subramaniam/tux2lab/issues      #
#----------------------------------------------------------------------------------------#
exec /tux2lab/ks-manage/prepare-distro-for-ksmanager.sh --download-infra-iso "$@"
