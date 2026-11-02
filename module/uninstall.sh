#!/system/bin/sh
MODDIR=${0%/*}

sh "$MODDIR/splitdns.sh" stop
rm -rf /data/adb/splitdns
