#! /bin/bash

shopt -s nocasematch

if [ "$(id -u)" != "0" ]; then
  echo "Sorry, this script must be run as root. (use 'sudo bash $0')"
  exit 1
fi

github="https://raw.githubusercontent.com/JohnKiel/plex-ssl/master"
confpath="/ubuntu/conf"
nginx="/etc/nginx"
certs="/opt/ssl-plex/certs"

proxy_key_path="$certs"
mitm_key_path="$certs"

proxy_pem="$proxy_key_path/proxy.pem"
proxy_key="$proxy_key_path/proxy.key"
proxy_csr="$proxy_key_path/proxy.csr"

mitm_key="$mitm_key_path/mitm.key"
mitm_pem="$mitm_key_path/mitm.pem"

basesecureport=30443 # don't change!
basedomain="my.externalhost.com" # don't change!
basehost="192.168.0.10" # don't change!
basepmsport=32400 # don't change!
thishost=`hostname -I|sed 's/ *$//'`

DISTRIB_DESCRIPTION="UNKNOWN OS"
notubuntu=true
if [ -f /etc/lsb-release ]; then
  . /etc/lsb-release
  notubuntu=false
fi
if $notubuntu; then
  echo "Sorry, this script will not run on this system.  Try Ubuntu Server 14.04.x"
fi

echo ""
echo "*** NOTICE ***"
echo "You are about to install and configure nginx and plex-ssl on $DISTRIB_DESCRIPTION"
echo "This installer assumes a fresh, minimal install of Ubuntu Server 14.04.x"
echo ""
echo "No other web server should be installed on this system."
echo "The proxy requires use of ports 80 and 443!"
echo "It also uses ports 3x443, and port 8099"
echo ""
echo "You will be required to copy/paste SSL certificate data to/from this script."
echo "To do so, you should be connected via SSH/terminal, not the local console."
echo ""
echo "This script may break things and otherwise complicate your life."
echo "Do you understand and accept?"
echo -n "Type 'yes' to continue:"
read confirm
if [ "$confirm" != "yes" ]; then
  echo "Goodbye."
  exit
fi

publicip=`wget -qO- icanhazip.com|sed 's/ *$//'`
#geojson=`wget -qO- http://freegeoip.net/json/`
geojson=`wget -qO- http://www.telize.com/geoip`

# see if we can get jq
if ! type "jq" > /dev/null; then
  echo ""
  echo "*** INSTALLING jq"
  apt-get -y -qq install jq
  echo ""
fi

if ! type "jq" > /dev/null; then
  "Sorry, this script requires 'jq'."
  exit 1
fi
countrycode=`echo "$geojson"|jq -r '.country_code'`
#state=`echo "$geojson"|jq -r '.region_name'`
state=`echo "$geojson"|jq -r '.region'`
city=`echo "$geojson"|jq -r '.city'`

echo ""
echo "Great! I'll need the domain name you'll be using to access your"
echo "Plex Media Server remotely, and securely."
echo ""
echo "NOTE: You must own the domain. You will be required to authenticate "
echo "      an SSL certificate with a valid Certificate Authority (CA),"
echo "      like StartSSL.com. (Only provider of free certs known to work.)"
echo ""
echo "      \"Free\" domains names from dyn.org, noip.com and the like" 
echo "      WILL NOT work. Your email address won't be one of the"
echo "      administrative/authoritative ones listed in the WHOIS record"
echo "      for the domain."
echo ""

# Get domain name that we'll evenually create an SSL cert for.
pms_domain=""
found=false
until $found; do
  echo "Domain Name (Example; $basedomain):"
  read pms_domain
  echo -n "*** CHECKING '$pms_domain'... "
  if [ ${#pms_domain} -gt 3 ]; then
    host $pms_domain
    if [ $? -eq 0 ]; then
      found=true
      hostip=`dig +short $pms_domain|sed 's/ *$//'`
      if [[ $pms_domain =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "Sorry, $pms_domain is an IP address.  You need to use a domain name."
        found=false
      elif [ "$hostip" != "$publicip" ]; then
        echo "$pms_domain does not resolve to your current public IP address, $publicip"
        echo -n "Are you sure you want to use '$pms_domain'? [yes/no]:"
        read check
        if [ "$check" != "yes" ]; then
          found=false
        fi
      fi
    else
      echo "$pms_domain is not a valid domain name."
    fi
  fi
  if $found; then
    echo "Using '$pms_domain'"
  else
    echo "This is not the domain you are looking for."
    echo "Please try again."
  fi
done

# Get IP address(s) of PMS server(s) we'll be proxying
echo ""
echo "Next, I'll need the local host name or IP address of your Plex Media Server(s)"
nomore=false
pms_hosts=()
index=0
until $nomore; do
  found=false
  until $found; do
    pms_secureport=$((basesecureport+index*1000))
    echo "Local Address for PMS server#$((index+1)) (Example; $basehost):"
    read pms_host
    echo "*** CHECKING '$pms_host':"
    if [ ${#pms_host} -gt 3 ]; then
      # Check if it's a PMS host
      wget -T 10 -t 1 http://$pms_host:$basepmsport/web/index.html -O /dev/null # >/dev/null 2>&1
      if [ $? -eq 0 ]; then
        pms_hosts+=("$pms_host")
        found=true
      fi
    fi
    if $found; then
      echo ""
      echo "$pms_host looks like a PMS server!"
      echo "Added: $pms_host"
      echo "Proxy will answer on https://$thishost:$pms_secureport and forward traffic to http://$pms_host:$basepmsport"
      echo "After this script is done, remember to:"
      echo "- Add a NAT rule to your firewall, forwarding TCP $pms_domain:$pms_secureport to $thishost:$pms_secureport"
      echo "- Configure the PMS server http://$pms_host:$basepmsport/web with:" 
      echo "  * \"Manually specify port\" $pms_secureport"
      echo "  * \"Require authentication on local networks\" checked!"
      echo "- Append CA cert (given later) to PMS's cacert.pem and install on host OS/browsers for $pms_host"
      echo "- Append '$thishost plex.tv' to $pms_host's 'hosts' file";
      echo ""
      ((index++))
    else
      echo ""
      echo "'$pms_host' doesn't appear to be a valid PMS server.  Please try again."
      echo ""
    fi
  done
  check=""
  until [ "$check" == "yes" ] || [ "$check" == "no" ]; do
    echo -n "Are you done adding PMS servers? [yes/no]:";
    read check
  done
  if [ "$check" == "yes" ]; then
    nomore=true
  fi
done

echo ""
echo "O.K.  Looks like you want to create a secure proxy for ${#pms_hosts[@]} PMS server(s)."
echo ""
echo "Now I'm going to set some stuff up."
echo "If you see any errors, something didn't work."
echo ""

# Install nginx with lua
echo "*** INSTALLING NIGNX"
apt-get -y install nginx-extras
if [ $? -gt 0 ]; then
  echo "ERROR installing nginx"
  exit 1
fi

# Make some directories we'll need
echo "*** CREATEING DIRECTORIES"
mkdir -p $mitm_key_path
if [ $? -gt 0 ]; then
  echo "ERROR creating directory $mitm_key_path"
  exit 1
fi
mkdir -p $proxy_key_path
if [ $? -gt 0 ]; then
  echo "ERROR creating directory $proxy_key_path"
  exit 1
fi

# Get files we'll need
echo "*** DOWNLOADING FILES"
wget -nv -O /tmp/plex.mitm.proxy $github$confpath/plex.mitm.proxy
if [ $? -gt 0 ]; then
  echo "ERROR getting $github$confpath/plex.mitm.proxy"
  exit 1
fi
wget -nv -O /tmp/plex.secure.proxy $github$confpath/plex.secure.proxy
if [ $? -gt 0 ]; then
  echo "ERROR getting $github$confpath/plex.secure.proxy"
  exit 1
fi

# remove old files
rm -f $nginx/sites-enabled/plex.secure.proxy-*
# Create the nginx config files
echo "*** GENERATING PROXY CONFIGURATION"
sed -e s/"$basedomain"/"$pms_domain"/g /tmp/plex.mitm.proxy > $nginx/sites-enabled/plex.mitm.proxy
if [ $? -gt 0 ]; then
  echo "ERROR generating $nginx/sites-enabled/plex.mitm.proxy"
  exit 1
fi

# loop over each PMS host and add a reverse proxy for them, 
# starting with port 30443 ($basesecureport), and incrementing by 1000 (30443, 31443, 32443, ...)
index=0
for pms_host in ${pms_hosts[@]}; do
  pms_secureport=$((basesecureport+index*1000))
  sed -e s/"$basedomain"/"$pms_domain"/g -e s/"$basehost"/"$pms_host"/g -e s/"$basesecureport"/"$pms_secureport"/g /tmp/plex.secure.proxy > $nginx/sites-enabled/plex.secure.proxy-$pms_secureport
  if [ $? -gt 0 ]; then
    echo "ERROR generating $nginx/sites-enabled/plex.secure.proxy-$pms_secureport"
    exit 1
  fi
  ((index++))
done

# Check if we already have MITM cert
key_check=""
openssl rsa -noout -modulus -in $mitm_key >/dev/null 2>&1
if [ $? -eq 0 ]; then
  key_check=`openssl rsa -noout -modulus -in $mitm_key | openssl md5`
fi

has_mitm=false
pem_check=""
openssl x509 -noout -modulus -in $mitm_pem >/dev/null 2>&1
if [ $? -eq 0 ]; then
  pem_check=`openssl x509 -noout -modulus -in $mitm_pem | openssl md5`
  if [ "$pem_check" == "$key_check" ]; then
    has_mitm=true
  fi
fi

docert=true
if $has_mitm; then
  echo "Looks like there is already a certificate and key for the MITM proxy." 
  echo -n "Do you want to generate a new ones? [no]:"
  read check
  if [ "$check" != "yes" ]; then
    docert=false
  fi
fi

if $docert; then
  # Start creating the certs
  echo "*** GENERATING CERTIFICATE FOR MITM PROXY"
  openssl genrsa -out $mitm_key 2048
  if [ $? -gt 0 ]; then
    echo "ERROR generating $mitm_key"
    exit 1
  fi
  openssl req -subj '/CN=plex.tv/O=Plex Man In the Middle Proxy./C=US' -x509 -new -nodes -key $mitm_key -days 1024 -out $mitm_pem
  if [ $? -gt 0 ]; then
    echo "ERROR generating $mitm_pem"
    exit 1
  fi
fi

# Check if there is a CSR
key_check=""
openssl rsa -noout -modulus -in $proxy_key >/dev/null 2>&1
if [ $? -eq 0 ]; then
  key_check=`openssl rsa -noout -modulus -in $proxy_key | openssl md5`
  echo "KEY: $key_check"
fi

has_csr=false
csr_check=""
openssl req -noout -modulus -in $proxy_csr >/dev/null 2>&1
if [ $? -eq 0 ]; then
  csr_check=`openssl req -noout -modulus -in $proxy_csr | openssl md5`
  if [ "$csr_check" == "$key_check" ]; then
    has_csr=true
  fi
fi

has_pem=false
pem_check=""
openssl x509 -noout -modulus -in $proxy_pem >/dev/null 2>&1
if [ $? -eq 0 ]; then
  # tmpfile="/tmp/first_in_bundle"
  # awk '/-----END/' RS= $proxy_pem > $tmpfile
  pem_check=`openssl x509 -noout -modulus -in $proxy_pem | openssl md5`
  echo "PEM: $pem_check"
  if [ "$pem_check" == "$key_check" ]; then
    has_pem=true
  fi
fi

docertpromt=true
showcsr=false
getkey=false
getpem=false
if $has_csr; then
  check=""
  until [ "$check" == "yes" ] || [ "$check" == "no" ]; do
    echo ""
    if $has_pem; then
      echo "Looks like you have a Certificate Signing Request (CSR), but "
      echo "there also appears to be a valid Signed Certificate."
      echo "You probably only want to do this again if you think you entered an"
      echo "intermediate certificate incorrectly."
    else
      echo "Looks like there is CSR waiting to be authenticated by a Certificate Authority."
    fi
    cn=`openssl req -noout -subject -in $proxy_csr | perl -ne 'print "$1" if m|.*CN=(.*?)(?:/[^/]*?=.*)?$|'`
    if [ "$cn" != "$pms_domain" ]; then
      echo ""
      echo "WARNING! The common name from this CSR, $cn, does not match"
      echo "         your domain name, $pms_domain.  It won't work this way!"
    fi
    echo ""
    echo -n "Do you want to continue the CSR process? [yes/no]:"
    read check
  done
  if [ "$check" == "yes" ]; then
    docertprompt=false
    showcsr=true
    getpem=true
  fi
fi

if $docertprompt; then
  docert=true
  # Check if we already have Secure Proxy cert
  if $has_pem; then
    echo ""
    echo "Looks like there is already a valid certificate and key for the secure proxy."
    cn=`openssl x509 -noout -subject -in $proxy_pem|perl -ne 'print "$1" if m|.*CN=(.*?)(?:/[^/]*?=.*)?$|'`
    if [ "$cn" != "$pms_domain" ]; then
      echo ""
      echo "WARNING! The common name from this certificate, $cn, does not match"
      echo "         your domain name, $pms_domain.  It won't work this way!"
    fi
    echo -n "Do you want to replace this certificate? [no]:"
    read check
    if [ "$check" != "yes" ]; then
      docert=false
    fi
  else
    echo ""
    echo "Looks like we don't yet have a key and certificate for the secure proxy."
  fi

  if $docert; then
    # Check if they want to use one they already have, or if they want to generate one
    check=""
    until [ "$check" == "new" ] || [ "$check" == "mine" ]; do
      echo ""
      echo "Would you like to add a key/cert you already have for $pms_domain,"
      echo "or, would you like to generate new ones?"
      echo ""
      echo -n "Generate new or enter existing? [new/mine]:"
      read check
    done
    if [ "$check" == "mine" ]; then
      getkey=true
      getpem=true
      showcsr=false
    else
      echo "*** GENERATING KEY/CSR FOR SECURE PROXY"
      # looks like we'll need to generate a new key and csr, then prompt for the pem
      tmpkey="/tmp/tmp_key" #yeah, probably not the most secure thing to do.
      tmpcsr="/tmp/tmp_csr"
      tmpconf="/tmp/tmp_openssh_conf"
      openssl genrsa -out $tmpkey 2048
      if [ $? -gt 0 ]; then
        echo "ERROR generating new external.key"
        exit 1
      fi
      echo "You'll need to enter information that will be used"
      echo "for a Certificate Signing Request (CSR)"
      echo ""
      echo "Make sure the information you enter is valid."
      echo "You're going to use this to request a Signed Certificate"
      echo "from a real Certificate Authority."
      echo ""
      echo "Answer the questions below:"
      # create some defaults for openssh
      cp -f /etc/ssl/openssl.cnf $tmpconf
      sed -i "s/\(countryName_default\s*=\s*\).*/\1$countrycode/" $tmpconf
      sed -i "s/\(stateOrProvinceName_default\s*=\s*\).*/\1$state/" $tmpconf
      sed -i "/\(localityName\s*=\s*\).*/a localityName_default = $city" $tmpconf
      sed -i "/\(commonName_max\s*=\s*\).*/a commonName_default = $pms_domain" $tmpconf
      sed -i "s/\(0.organizationName_default\s*=\s*\).*/\1N\/A/" $tmpconf

      # prompt them
      cn=""
      until [ "$cn" == "$pms_domain" ]; do
        openssl req -new -config $tmpconf -key $tmpkey -out $tmpcsr
        if [ $? -gt 0 ]; then
          echo "ERROR generating new external.csr"
          exit 1
        fi
        cn=`openssl req -noout -subject -in $tmpcsr|perl -ne 'print "$1" if m|.*CN=(.*?)(?:/[^/]*?=.*)?$|'`
        if [ "$cn" != "$pms_domain" ]; then
          echo ""
          echo "Sorry, $cn does not match the domain name you chose earlier, $pms_domain"
          echo "Please try again."
          echo ""
        fi
      done
      # if we got here, lets copy the temp certs to the real location
      cp -f $tmpkey $proxy_key
      if [ $? -gt 0 ]; then
        echo "ERROR copying new proxy key"
        exit 1
      fi
      cp $tmpcsr $proxy_csr
      if [ $? -gt 0 ]; then
        echo "ERROR copying new proxy csr"
        exit 1
      fi
      showcsr=true
      getpem=true
      getkey=false
    fi
  fi
fi

if $getkey; then
  tmpfile="/tmp/tmp_key"
	rm -f $tmpfile
	echo "*** GET PRIVATE KEY FOR SECURE PROXY SERVER "
	echo "Paste your private key below."
	echo " - Alternativly, you could sftp your key and certificate to:" 
	echo "   $proxy_key"
	echo "   $proxy_pem"
	echo "Paste everything between and including"
	echo "-----BEGIN RSA PRIVATE KEY----- and -----END RSA PRIVATE KEY-----"
	echo ""
	echo "Paste The Private Key:"
	complete=false
	linecount=0
	until $complete; do
	  read line
		if [ ${#line} -gt 0 ]; then
		  echo "$line" >> $tmpfile
		  ((linecount++))
		fi
		if [[ $line =~ ^-----END ]]; then
		  openssl rsa -noout -modulus -in $tmpfile >/dev/null 2>&1
		  if [ $? -gt 0 ]; then
                    echo "Sorry, the data you entered isn't a valid key"
		  else
                    echo ""
                    echo "Got the private key!"
                    echo ""
                    complete=true
		  fi
		fi
	done
	cp -f $tmpfile $proxy_key
        if [ $? -gt 0 ]; then
          echo "ERROR copying your proxy key"
          exit 1
        fi
fi

# Check if we need to process the CSR
if $showcsr; then
  echo "*** PROCESSING CSR"
  echo "Copy and paste the Certificate Signing Request (CSR) to your chosen CA."
  echo "(Alternativly, you could find the CSR in $proxy_csr)"
  echo "The CA will need everything between and inlcuding"
  echo "-----BEGIN CERTIFICATE REQUEST----- and -----END CERTIFICATE REQUEST-----"
  echo ""
  cat $proxy_csr
  if [ $? -gt 0 ]; then
    echo "ERROR displaying CSR file"
      exit 1
  fi
  echo ""
fi

if $getpem; then
  success=false
  count=0;
  key_check=`openssl rsa -noout -modulus -in $proxy_key | openssl md5`
  tmpbase="/tmp/tmp_cert_"
  tmpfiles=()
  until $success; do
    tmpfile="$tmpbase$count"
    rm -f $tmpfile
    echo "*** GET SIGNED/INTERMEDIATE CERTIFICATE(S)"
    echo "Paste the certificate you recived from your CA below."
	echo "(Alternativly, you could sftp your cert to $proxy_pem)"
    echo "Paste everything between and including"
    echo "-----BEGIN CERTIFICATE----- and -----END CERTIFICATE-----"
    echo ""
    echo "If your CA uses intermediate certificates, you will be promped" 
    echo "for them one at a time.  They must be entered in the proper"
    echo "order.  DO NOT paste all of them at one time."
    echo ""
    if [ $count -gt 0 ]; then
      echo "Paste Intermediate Certificate #$count, or \"DONE\" if complete:"
    else
      echo "Paste The Signed Certificate:"
    fi
    complete=false
    linecount=0
    until $complete; do
      read line
      if [ "$line" != "DONE" ]; then
        if [ ${#line} -gt 0 ]; then
          echo "$line" >> $tmpfile
          ((linecount++))
        fi
        if [[ $line =~ ^-----END ]]; then
          openssl x509 -noout -modulus -in $tmpfile >/dev/null 2>&1
          if [ $? -gt 0 ]; then
            echo "Sorry, the data you entered isn't a valid certificate"
          else
            cert_check=`openssl x509 -noout -modulus -in $tmpfile | openssl md5`
            if [ $count -eq 0 ]; then
              # this should be the signed certificate
              if [ "$cert_check" == "$key_check" ]; then
                cn=`openssl x509 -noout -subject -in $tmpfile|perl -ne 'print "$1" if m|.*CN=(.*?)(?:/[^/]*?=.*)?$|'`
                if [ "$cn" != "$pms_domain" ]; then
                  echo ""
                  echo "Sorry, common name from this certificate, $cn, does not match"
                  echo "your domain name, $pms_domain.  It probably wont work."
                  echo "Please use a certificate that matches, or cancel and use the correct domain."
                  echo ""
                  check=""
                  until [ "$check" == "yes" ] || [ "$check" == "no" ]; do
                    echo -n "Are you sure you want to use this certificate? [yes/no]:";
                    read check
                  done
                  if [ "$check" == "yes" ]; then
                    ((count++))
                    tmpfiles+=("$tmpfile")
                    echo ""
                    echo "Will do."
                    echo "Now you'll need to enter your intermediate certificates, if there are any."
                    echo ""
                  fi
                else
                  echo ""
                  echo "The signed certificate looks good!"
                  echo ""
                  echo "Now you'll need to enter your intermediate certificates, if there are any."
                  echo ""
                  ((count++))
                  tmpfiles+=("$tmpfile")
                fi
              else
                echo ""
                echo "Sorry, the certificate you entered doesn't match your private key."
                echo "Please try again."
                echo ""
              fi
            else
              # this should be an intermediate cert
              if [ "$cert_check" == "$key_check" ]; then
                echo ""
                echo "Oops. It looks like you entered your signed certificate as an intermediate."
                echo "Please try again, or enter \"DONE\" if you're all done."
                echo ""
              else
                echo ""
                echo "O.K!  Got your intermediate certificate #$count"
                echo ""
                ((count++))
                tmpfiles+=("$tmpfile")
              fi
            fi
          fi
          complete=true
        fi
      else
        if [ $linecount -eq 0 ] && [ $count -gt 0 ]; then
          complete=true
          success=true
        elif [ $count -eq 0 ]; then
          echo "Sorry, you haven't entered a complete signed certificate.  Can't be done yet."
        else
          echo "Sorry, you already started entering data. Can't be done now."
        fi
      fi
    done
  done
  # create a unified pem
  tmpbundle=${tmpbase}bundle
  rm -f $tmpbundle
  for tmpfile in ${tmpfiles[@]}; do
    cat $tmpfile >> $tmpbundle
    if [ $? -gt 0 ]; then
      echo "ERROR creating PEM bundle"
        exit 1
    fi
  done
  cp -f $tmpbundle $proxy_pem
  if [ $? -gt 0 ]; then
    echo "ERROR copying PEM bundle"
      exit 1
  fi

fi

service nginx restart
if [ $? -gt 0 ]; then
  echo "ERROR nginx did not restart properly"
  exit 1
fi

echo "YAY! The secure proxy should be ready!"
echo ""
echo "Remember that you'll need to add the following line to your PMS server's \"hosts\" file:"
echo "$thishost plex.tv"
echo ""
echo "The hosts file for Windows is in:"
echo "C:\Windows\System32\drivers\etc\hosts"
echo ""
echo "For Linux,etc.:"
echo "/etc/hosts"
echo ""
echo "For Max OSX:"
echo "/private/etc/hosts"
echo ""
echo "You will also need to install the following certificate on all PMS servers,"
echo "both in the operating system, and in PMS's cacerts.pem file by appending it to the end."
echo ""
cat $mitm_pem
if [ $? -gt 0 ]; then
  echo "ERROR displaying MITM certificate"
    exit 1
fi

echo ""
echo "Remember to add port mappings in your router for:"
# loop over each PMS host
# starting with port 30443 ($basesecureport), and incrementing by 1000 (30443, 31443, 32443, ...)
index=0
for pms_host in ${pms_hosts[@]}; do
 pms_secureport=$((basesecureport+index*1000))
 echo "TCP external:$pms_secureport TO $thishost:$pms_secureport (NGINX will forward to $pms_host:32400)"
 ((index++))
done
