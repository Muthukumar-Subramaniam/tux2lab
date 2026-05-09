#!/bin/bash

while :
do
	echo
	read -p "Enter number of random hosts required ( Max 1000 ) : " v_input_number

	if [[ "${v_input_number}" =~ ^[1-9][0-9]{0,2}$|^1000$ ]]; then

		break
	else
    		echo -e "\n\nInvalid input. Please enter a number between 1 and 1000."
		continue
	fi
done

> tmp_hosts

echo -e "\nGenerating ${v_input_number} random hosts as requested . . .\n"

for _ in $( seq 1 ${v_input_number} )
do
	while :
	do
		v_random_number=$((RANDOM % 9000 + 1000))

		if grep ${v_random_number} tmp_hosts &>/dev/null
		then
			continue
		fi

		echo "mshost${v_random_number}" | tee -a tmp_hosts

		break
	done
done

sort tmp_hosts > hosts

rm -f tmp_hosts

echo -e "\nAs requested, ${v_input_number} random hosts are generated and stored in file \"hosts\"\n"
