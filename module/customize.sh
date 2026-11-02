#!/system/bin/sh
# KernelSU / Magisk installer hook

case "$ARCH" in
  arm64) src=dnsproxy-arm64 ;;
  arm) src=dnsproxy-arm ;;
  *) abort "Unsupported architecture: $ARCH" ;;
esac
[ -f "$MODPATH/bin/$src" ] || abort "bin/$src is missing from the zip"
mv -f "$MODPATH/bin/$src" "$MODPATH/bin/dnsproxy"
rm -f "$MODPATH"/bin/dnsproxy-*

DATA=/data/adb/splitdns
mkdir -p "$DATA"
if [ -f "$DATA/domains.txt" ]; then
  ui_print "- Keeping existing $DATA/domains.txt"
else
  cp -f "$MODPATH/domains.txt" "$DATA/domains.txt"
  ui_print "- Default config copied to $DATA/domains.txt"
fi

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/bin/dnsproxy" 0 0 0755
set_perm "$MODPATH/splitdns.sh" 0 0 0755
ui_print "- Edit $DATA/domains.txt, then press Action (or reboot)"
ui_print "- Turn Private DNS off: it bypasses this module"
