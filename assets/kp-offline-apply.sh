#!/bin/sh
set -e
BACK=/etc/opkg/distfeeds.conf.kp.bak
CFB=/etc/opkg/customfeeds.conf.kp.bak
CF=/etc/opkg/customfeeds.conf
[ -f /etc/opkg/distfeeds.conf ] && cp -f /etc/opkg/distfeeds.conf "$BACK" || true
[ -f "$CF" ] && cp -f "$CF" "$CFB" || true
# 避免 customfeeds 里再挂一份 HTTPS，导致 opkg 仍去拉已失效的 SNAPSHOT
echo "# add your custom package feeds here" >"$CF"
ROOT=/tmp/kp-offline-feed
{
	echo "# kp-offline: file:// feeds (PC-uploaded Packages.gz)"
	for d in "$ROOT"/*; do
		[ -d "$d" ] || continue
		[ -f "$d/Packages.gz" ] || continue
		name=$(basename "$d")
		echo "src/gz $name file://$ROOT/$name"
	done
} >/etc/opkg/distfeeds.conf
echo WROTE_DISTFEEDS
opkg update || {
	echo OPKG_UPDATE_FAIL
	exit 1
}
echo OPKG_UPDATE_OK
