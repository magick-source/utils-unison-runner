# unison-runner

Unison Runner is a tool to keep directories in sync using Unison.
It shows up in the systray and show you the current synchronization status
of your directories (up-to-date, syncing, offline, etc).

It doesn't handle any of the synchronization, that is left to unison, and
it doesn't not try to be smart on how to use unison. It does very little.

It uses a config file, by default in ~/.config/unison-runner.cfg, but a
different one can be passed with **-c <filepath>**.

The main feature of the unison runner is it systray status icon.

![all good](shots/icon-ok.png "all good icon") - this means all the syncs have
runned without issues the last time.



![main window](shots/window.png "main window")



## potential WTFs

* **skiped is remote is empty** - I use this to synchronize between my
desktop and my SMB NAS. I mount the NAS using ftab mounts. In my setup
if the remote directory is empty, it means that the share was not mounted,
so I don't want to run unison on that empty directory. If you are starting
to sync files to a new, empty share, you can manual run the unison command
once - you can get it from the log window of your sync.

* **smbnetfs doesn't work** - well, maybe it does for you, but I didn't
manage to make it work on my setup, and didn't want to spend too much time
time making it work, specially because I don't have problems mounting my
shares with ftab entries. If you manage to make unison work with smbnetfs
tell me how, please.

