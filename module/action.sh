#!/system/bin/sh
# KernelSU Action button: drop old rules and apply domains.txt again
MODDIR=${0%/*}

sh "$MODDIR/splitdns.sh" restart
echo
sh "$MODDIR/splitdns.sh" status
