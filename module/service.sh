#!/system/bin/sh
MODDIR=${0%/*}

until [ "$(getprop sys.boot_completed)" = 1 ]; do sleep 2; done
sleep 5
sh "$MODDIR/splitdns.sh" start
