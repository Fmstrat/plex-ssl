plex-ssl
========

A guide to using NGINX to secure Plex via SSL.

This guide was developed for CentOS 6.5 with EPEL enabled. To enable EPEL in CentOS 6.5, please visit this guide: http://www.tecmint.com/how-to-enable-epel-repository-for-rhel-centos-6-5/

For the sake of this guide, the following settings are used:
- Internal PMS hostname: *pms-vm*
- Internal PMS IP: *192.168.3.207*
- External hostname: *my.externalhost.com*
- External port: *33443*

Setup your firewall
--------------

Use the following port forwarding options on your firewall.
- External port 33443 -> pms-vm:33443


Download and install Plex
--------------
Use the following commands to download and install Plex. You can get the URL for the latest version of Plex from https://plex.tv/downloads

```
[root@pms-vm ~]# wget http://downloads.plexapp.com/plex-media-server/0.9.9.14.531-7eef8c6/plexmediaserver-0.9.9.14.531-7eef8c6.x86_64.rpm
[root@pms-vm ~]# rpm -Uvh plexmediaserver-0.9.9.14.531-7eef8c6.x86_64.rpm
[root@pms-vm ~]# service plexmediaserver start
[root@pms-vm ~]# chkconfig plexmediaserver on
```

Now, configure Plex:
- Visit: http://pms-vm:32400/web/index.html#!/settings/server
- Goto **Connect**, sign in to Plex
- Click **SHOW ADVANCED**
- Check **Manually specify port**
- Fill in 33443
- Check **Require authentication on local networks**
- Lastly, add media to your library


Edit your hosts file
--------------

To fake PMS into connecting to your proxy, and to route all traffic from the internet to PMS, we must make the machine beleive plex.tv is the localhost, and provide another hostname for the real plex.tv IP for outbound contact.

```
[root@pms-vm ~]# vi /etc/hosts
```
And add:
```
184.169.179.97 realplex.tv
192.168.3.207	plex.tv
```

Set up your certificates
--------------

We will need two sets of certificates, one that is used as a Man In The Middle (MITM) certificate that PMS will use when connecting to the "fake" plex.tv host, and another, trusted certificate to use when external hosts connect to your system. The free certs from http://StartSSL.com has been verified to work on Android and Plex Web so far.

First, create your MITM certificate, and add it to PMS:
```
[root@pms-vm ~]# mkdir -p /etc/pki/tls/certs/mitm
[root@pms-vm ~]# cd /etc/pki/tls/certs/mitm
[root@pms-vm mitm]# openssl genrsa -out MITM_CA.key 2048
```
Which should return:
```
Generating RSA private key, 2048 bit long modulus
..............................+++
..........+++
e is 65537 (0x10001)
```
And then run:
```
[root@pms-vm mitm]# openssl req -x509 -new -nodes -key MITM_CA.key -days 1024 -out MITM_CA.pem
```
And use the following values. Be sure to enter **plex.tv** as the **Common Name**.
```
You are about to be asked to enter information that will be incorporated
into your certificate request.
What you are about to enter is what is called a Distinguished Name or a DN.
There are quite a few fields but you can leave some blank
For some fields there will be a default value,
If you enter '.', the field will be left blank.
-----
Country Name (2 letter code) [XX]:US
State or Province Name (full name) []:
Locality Name (eg, city) [Default City]:
Organization Name (eg, company) [Default Company Ltd]:
Organizational Unit Name (eg, section) []:
Common Name (eg, your name or your server's hostname) []:plex.tv
Email Address []:
```

Then set permissions and integrate into PMS:
```
[root@pms-vm mitm]# chmod 600 *
[root@pms-vm mitm]# cp /usr/lib/plexmediaserver/Resources/cacert.pem /usr/lib/plexmediaserver/Resources/cacert.pem.orig
[root@pms-vm mitm]# echo "" >> /usr/lib/plexmediaserver/Resources/cacert.pem
[root@pms-vm mitm]# echo "MITM" >> /usr/lib/plexmediaserver/Resources/cacert.pem
[root@pms-vm mitm]# echo "=========================" >> /usr/lib/plexmediaserver/Resources/cacert.pem
[root@pms-vm mitm]# cat MITM_CA.pem >> /usr/lib/plexmediaserver/Resources/cacert.pem
```

Now we need to setup our external, valid certificate:
```
[root@pms-vm mitm]# mkdir -p /etc/pki/tls/certs/external
[root@pms-vm external]# cd /etc/pki/tls/certs/external
```
At this point, you should place your external, valid certificate and key here. We will call these **external.cer** and **external.key** from here out. If you are using a lower priced certificate, you will likely also have a Certificate Authority file, which we will call **CA.cer**. You should combine this and your external certificate into one file at this point, and set permissions:
```
[root@pms-vm external]# cat CA.cer > external.bundle.cer
[root@pms-vm external]# cat external.cer >> external.bundle.cer
[root@pms-vm external]# chmod 600 *
```

Install nginx
--------------

In Ubuntu, this could be as easy as installing the nginx and nginx-lua packages, but CentOS does not have a preconfigured nginx with lua available, even in EPEL. To overcome this, we will use the openresty packages from http://openresty.org/

```
[root@pms-vm external]# yum install gcc pcre-devel openssl-devel
[root@pms-vm external]# mkdir -p /opt/ngx
[root@pms-vm external]# cd /opt/ngx
[root@pms-vm ngx]# wget http://openresty.org/download/ngx_openresty-1.7.0.1.tar.gz
[root@pms-vm ngx]# tar xvfz ngx_openresty-1.7.0.1.tar.gz
[root@pms-vm ngx]# cd ngx_openresty-1.7.0.1
[root@pms-vm ngx_openresty-1.7.0.1]# ./configure --with-luajit
[root@pms-vm ngx_openresty-1.7.0.1]# gmake
[root@pms-vm ngx_openresty-1.7.0.1]# gmake install
```

Now we need to configure nginx. First, backup the original configuration and edit the file:
```
[root@pms-vm ngx_openresty-1.7.0.1]# cd
[root@pms-vm ~]# cp /usr/local/openresty/nginx/conf/nginx.conf /usr/local/openresty/nginx/conf/nginx.conf.orig
[root@pms-vm ~]# vi /usr/local/openresty/nginx/conf/nginx.conf
```

Then replace the contents of that file with the file located here: https://raw.githubusercontent.com/Fmstrat/plex-ssl/master/conf/nginx.conf

Make sure you replace the external hostname and two occurances of your internal IP.

Test the configuration with:
```
[root@pms-vm ~]# /usr/local/openresty/nginx/sbin/nginx -t
```

And if everything is OK, start up nginx and restart PMS:
```
[root@pms-vm ~]# /usr/local/openresty/nginx/sbin/nginx
[root@pms-vm ~]# service plexmediaserver restart
```

You can then follow the log files in */usr/local/openresty/nginx/logs* to make sure everything is functioning properly

Known problems
--------------

The following is a list of known issues thus far:
- Due to Plex.tv's use of unsecure Web Sockets, using the plex.tv host will still attempt to communicate via HTTP. This should not be an security issue for external hosts if no HTTP ports are open, as the vulnerable token would not be transmitted until a connection is established, but it does create problems with functionality.
