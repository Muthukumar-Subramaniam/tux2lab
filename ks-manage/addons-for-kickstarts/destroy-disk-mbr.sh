#!/bin/bash

if [[ "$1" == "-y" ]]
then
        :
else
        while :
        do
                echo
		read  -p "Do you really want to run this script $(basename $0) on $(hostname -f) ? (yes/no) : " v_get_confirmation
                if [[ "$v_get_confirmation" == "yes" ]]
                then
                        break
                elif [[ "$v_get_confirmation" == "no" ]]
                then
                        echo -e "\nExiting without any changes!\n"
                        exit
                else
                        echo -e "\nInvalid Input!\n"
                        continue
                fi
        done
fi

dd if=/dev/zero of=/dev/get_disk_type_for_the_vm bs=512 count=1
