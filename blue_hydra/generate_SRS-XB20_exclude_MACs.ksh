#!/bin/ksh

# generates exclude list for SRS-XB20 speakers
# for populating blue_hydra.yml in the ignore_mac section

set -A hex_list 0 1 2 3 4 5 6 7 8 9 A B C D E F

for first_character in ${hex_list[@]}
do
	for second_character in ${hex_list[@]}
	do
		echo "${first_character}${second_character}:D5:0B:89:CA:DC"
	done
done
