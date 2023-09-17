#!/bin/ksh

# stop blue_hydra in its screen session

screen -x bh_terminal -p 0 -X stuff "q"`echo -ne '\015'`
screen -x bh_terminal -p 0 -X stuff "exit"`echo -ne '\015'`
