#**plex-ssl**
--------------

*NOTE:* This does not work yet.

The provided nginx config file is intended to drop all HTTP connections coming into Plex before the access token is exposed. If you are interested in reading about the original SSL proof of concept and the fixes that went into that prior to the full release of SSL by Plex, please see the [original version](https://github.com/Fmstrat/plex-ssl/blob/master/README.md).

It is our hope that Plex will drop all HTTP packets by default when SSL is set to "Required" on the server in the future, thus making this github repository outdated. At this time that has not occured, and this guide will be updated when that occurs.
