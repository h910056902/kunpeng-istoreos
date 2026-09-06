#!/bin/sh
if [ -f /etc/opkg/distfeeds.conf.kp.bak ]; then
	cp -f /etc/opkg/distfeeds.conf.kp.bak /etc/opkg/distfeeds.conf && echo RESTORE_DISTFEEDS_OK || echo RESTORE_DISTFEEDS_FAIL
else
	echo NO_DISTFEEDS_BAK
fi
if [ -f /etc/opkg/customfeeds.conf.kp.bak ]; then
	cp -f /etc/opkg/customfeeds.conf.kp.bak /etc/opkg/customfeeds.conf && echo RESTORE_CUSTOMFEEDS_OK || echo RESTORE_CUSTOMFEEDS_FAIL
else
	echo NO_CUSTOMFEEDS_BAK
fi
