#!/bin/bash

DIR=$(dirname -- "$BASH_SOURCE")

export HOME=$DIR

# sync dirs first
unison -log=false "$HOME/local/" "$HOME/remote/" -ignorearchives

if [ ! -d $HOME/local ]; then
  mkdir $HOME/local
fi
if [ ! -d $HOME/remote ]; then
  mkdir $HOME/remote
fi

echo Generating files
touch $HOME/remote/make_it_work.txt

for f in $(seq -w 1 100); do
  for i in $(seq 1 100); do
    echo $RANDOM >> "$HOME/local/lfile$f.txt"
  done
done

echo Syncing - quit after 10 seconds, when done

$HOME/../unison-runner.pl -c $HOME/config.cfg -r 10

for f in $(seq -w 1 100); do
  diff "$HOME/local/lfile$f.txt" "$HOME/remote/lfile$f.txt" >/dev/null \
    || echo "lfile$f.txt is different"
done

rm $HOME/local/* $HOME/remote/*
rm -rfv $HOME/.unison


