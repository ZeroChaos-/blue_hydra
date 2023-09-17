#!/bin/ksh

# Blue Hydra Daemon Launcher

# find blue_hydra.rb under /root

blue_hydra_binary=$(find /root -name blue_hydra -type f)

# launch custom screen session for blue_hydra
# this gives the option to connect to that screen to see live results
# the screen session can be found by running "screen -list"

screen -mdS "bh_terminal"
screen -S "bh_terminal" -X stuff "$blue_hydra_binary --no-db"`echo -ne '\015'`
screen -S "bh_terminal" -X stuff `echo -ne '\015'`

# run in no-db mode by default
# for normal operation, only have the db in memory so that excessive writing to disk is avoided
