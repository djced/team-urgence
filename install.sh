#!/bin/bash
which sudo >/dev/null && prefix="sudo"
prefix="sudo"
[ ${USER} == "root" ] && prefix=""

if [ "$USER" != "root" ]; then
    groups | grep sudo >/dev/null
    if [ "$?" != "0" ]; then
        echo "You user isn't in sudo group"
        echo "Please add that user in sudo group with an administator account"
        echo "with the command: usermod -aG sudo $USER"
        exit 1
    fi
fi


echo -e "\E[031mPLEASE, NOTE THAT IMPORTANT INFORMATION\E[0m"
cat <<EOF
This script is a simple automation to install meet.jit.si and mattermost
on a server in urgence mode. That means that:
- you will use the domain name "xip.io" (e.g. meet.your.ip.address.xip.xio)
- certificates are not validate, so the users will need to accept default certificate

It will install docker and docker-compose if they are not already installed.
It will install nginx.
It will write configuration for nginx in /etc/nginx/sites-available/
It will create a user named team-urgence that will be in "docker" group
to launch mattermost and meet.jit.si
Create /opt/mattermost-docker and /opt/docker-jitsi-meet direcotries where
resides configuration and docker-compose files.

I'm not responsible on you server and how you use the script !

In the next futre, the author of that easy script will provide you a new script that will
help you to change you domain name and use let's encrypt to have a valid certificate.

Keep informed on https://github.com/metal3d/team-urgence

Enjoy !
Press any key to continue, or CTRL+C to cancel...
EOF
read


_PUBLICIP=$(wget -qO- http://whatismyip.akamai.com/)
_PRIVATEIP=$(ip r get 1 | grep -Po '(\d+.){4}' | tail -n1)

echo "Choose how to connect your services:"
echo "1 - With private IP, only users in you local network via xxx.${_PRIVATEIP}.xip.io"
echo "2 - With public IP, users can see your services on internet via xxx.${_PUBLICIP}.xip.io"

RESP="-"
while [ "$RESP" != '1' ] && [ "$RESP" != '2' ]; do
    echo -n "Choose 1 or 2: "
    read -a RESP
done

case $RESP in
    1)
        IP=${_PRIVATEIP}
        ;;
    2)
        IP=${_PUBLICIP}
        ;;
esac

# remove blank
IP=$(echo $IP)

echo "After installation, you will be able to connect:"
echo "https://meet.${IP}.xip.io to make visioconference"
echo "http://chat.${IP}.xip.io to chat with team, exchange files..."
for i in in {1..10}; do
    printf "\rYou've got 10s to cancel by pressing CTRL+C: %1d " "$((10-i))"
    sleep 1
done
echo

grep "team-urgence" /etc/password >/dev/null
if [ "$?" != "0" ]; then
    echo "===> Create a team-urgence user"
    $prefix apt update
    $prefix apt install sudo
    $prefix useradd -m -s /bin/bash team-urgence
    # and create a password for that user:
    # with a strong password
    echo "===> Give a password for team-urgence user please:"
    $prefix passwd team-urgence
fi

# Install nginx
cd
$prefix apt update
$prefix apt install ssl-cert git nginx -y
$prefix systemctl enable nginx
$prefix systemctl start nginx

# install docker
which docker
if [ "$?" != 0 ]; then
	wget -O- https://get.docker.com | bash -
fi
$prefix usermod -aG docker team-urgence

# install docker-compose
which docker-compose >/dev/null
if [ "$?" != 0 ]; then
	$prefix wget https://github.com/docker/compose/releases/download/1.26.0-rc3/docker-compose-Linux-x86_64 -O /usr/local/bin/docker-compose
	$prefix chmod +x /usr/local/bin/docker-compose
fi

# install mattermost
git clone https://github.com/mattermost/mattermost-docker.git /tmp/mattermost-docker
cd /tmp/mattermost-docker
mkdir -pv ./volumes/app/mattermost/{data,logs,config,plugins,client-plugins}
cat 1> docker-compose.yml <<EOF
version: "3"

services:
  db:
    build: db
    read_only: true
    restart: unless-stopped
    volumes:
      - ./volumes/db/var/lib/postgresql/data:/var/lib/postgresql/data
      - /etc/localtime:/etc/localtime:ro
    environment:
      - POSTGRES_USER=mmuser
      - POSTGRES_PASSWORD=mmuser_password
      - POSTGRES_DB=mattermost
  app:
    build:
      context: app
      args:
        - edition=team
    restart: unless-stopped
    ports:
      - 8000:8000
    volumes:
      - ./volumes/app/mattermost/config:/mattermost/config:rw
      - ./volumes/app/mattermost/data:/mattermost/data:rw
      - ./volumes/app/mattermost/logs:/mattermost/logs:rw
      - ./volumes/app/mattermost/plugins:/mattermost/plugins:rw
      - ./volumes/app/mattermost/client-plugins:/mattermost/client/plugins:rw
      - /etc/localtime:/etc/localtime:ro
    environment:
      - MM_USERNAME=mmuser
      - MM_PASSWORD=mmuser_password
      - MM_DBNAME=mattermost
      - MM_SQLSETTINGS_DATASOURCE=postgres://mmuser:mmuser_password@db:5432/mattermost?sslmode=disable&connect_timeout=10
EOF

cd
$prefix mv /tmp/mattermost-docker /opt/mattermost-docker
$prefix chown -R team-urgence /opt/mattermost-docker
sudo -u team-urgence bach -c "cd /opt/mattermost-docker && docker-compose build"
$prefix chown -R 2000:2000 /opt/mattermost-docker/volumes/app/mattermost/
sudo -u team-urgence bash -c "cd /opt/mattermost-docker && docker-compose up -d"


## configure nginx
cat 1> /tmp/mattermost.conf <<EOF
map \$http_x_forwarded_proto \$proxy_x_forwarded_proto {
  default \$http_x_forwarded_proto;
  ''       \$scheme;
}


server {
    listen 80;
    server_name chat.${IP}.xip.io;
    return 301 https://\$host\$request_uri;
}

server {
    server_name chat.${IP}.xip.io;
    listen 443 ssl;
    ssl_certificate /etc/ssl/certs/ssl-cert-snakeoil.pem;
    ssl_certificate_key /etc/ssl/private/ssl-cert-snakeoil.key;

    location ~ /api/v[0-9]+/(users/)?websocket$ {
        proxy_set_header Upgrade  \$http_upgrade;
        proxy_set_header Connection "upgrade";
        client_max_body_size 50M;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$proxy_x_forwarded_proto;
        proxy_set_header X-Frame-Options SAMEORIGIN;
        proxy_buffers 256 16k;
        proxy_buffer_size 16k;
        proxy_read_timeout 600s;
        proxy_pass http://127.0.0.1:8000;
    }

    location / {
        gzip on;
        client_max_body_size 50M;
        proxy_set_header Connection "";
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$proxy_x_forwarded_proto;
        proxy_set_header X-Frame-Options SAMEORIGIN;
        proxy_buffers 256 16k;
        proxy_buffer_size 16k;
        proxy_read_timeout 600s;
        proxy_pass http://127.0.0.1:8000;
    }
}
EOF
$prefix mv /tmp/mattermost.conf /etc/nginx/sites-available/mattermost.conf
$prefix ln -sf /etc/nginx/sites-available/mattermost.conf /etc/nginx/sites-enabled/mattermost.conf
$prefix nginx -s reload


## Jitsi
cd 
grep "chat.${IP}.xip.io" /etc/hosts || echo "127.0.0.1 chat.${IP}.xip.io" | sudo tee -a /etc/hosts

# clone and configure
git clone https://github.com/jitsi/docker-jitsi-meet /tmp/docker-jitsi-meet
cd /tmp/docker-jitsi-meet
mkdir -p .jitsi-meet-cfg/{web/letsencrypt,transcripts,prosody,jicofo,jvb}

cp env.example .env
sed -i 's/#DISABLE_HTTPS=1/DISABLE_HTTPS=1/' .env
sed -i 's,#PUBLIC_URL="https://meet.example.com",#PUBLIC_URL="https://meet.'${IP}'.xip.io",' .env
sed -i 's/HTTP_PORT=8000/HTTP_PORT=8080/' .env
sed -i 's,CONFIG=~/.jitsi-meet-cfg,CONFIG=/opt/docker-jitsi-meet/.jitsi-meet-cfg,' .env

cat > docker-compose.yml <<EOF
version: '3'

services:
    # Frontend
    web:
        image: jitsi/web
        ports:
            - '\${HTTP_PORT}:80'
            - '\${HTTPS_PORT}:443'
        restart: unless-stopped
        volumes:
            - \${CONFIG}/web:/config
            - \${CONFIG}/web/letsencrypt:/etc/letsencrypt
            - \${CONFIG}/transcripts:/usr/share/jitsi-meet/transcripts
        environment:
            - ENABLE_AUTH
            - ENABLE_GUESTS
            - ENABLE_LETSENCRYPT
            - ENABLE_HTTP_REDIRECT
            - ENABLE_TRANSCRIPTIONS
            - DISABLE_HTTPS
            - JICOFO_AUTH_USER
            - LETSENCRYPT_DOMAIN
            - LETSENCRYPT_EMAIL
            - PUBLIC_URL
            - XMPP_DOMAIN
            - XMPP_AUTH_DOMAIN
            - XMPP_BOSH_URL_BASE
            - XMPP_GUEST_DOMAIN
            - XMPP_MUC_DOMAIN
            - XMPP_RECORDER_DOMAIN
            - ETHERPAD_URL_BASE
            - TZ
            - JIBRI_BREWERY_MUC
            - JIBRI_PENDING_TIMEOUT
            - JIBRI_XMPP_USER
            - JIBRI_XMPP_PASSWORD
            - JIBRI_RECORDER_USER
            - JIBRI_RECORDER_PASSWORD
            - ENABLE_RECORDING
        networks:
            meet.jitsi:
                aliases:
                    - \${XMPP_DOMAIN}

    # XMPP server
    prosody:
        image: jitsi/prosody
        restart: unless-stopped
        expose:
            - '5222'
            - '5347'
            - '5280'
        volumes:
            - \${CONFIG}/prosody:/config
        environment:
            - AUTH_TYPE
            - ENABLE_AUTH
            - ENABLE_GUESTS
            - GLOBAL_MODULES
            - GLOBAL_CONFIG
            - LDAP_URL
            - LDAP_BASE
            - LDAP_BINDDN
            - LDAP_BINDPW
            - LDAP_FILTER
            - LDAP_AUTH_METHOD
            - LDAP_VERSION
            - LDAP_USE_TLS
            - LDAP_TLS_CIPHERS
            - LDAP_TLS_CHECK_PEER
            - LDAP_TLS_CACERT_FILE
            - LDAP_TLS_CACERT_DIR
            - LDAP_START_TLS
            - XMPP_DOMAIN
            - XMPP_AUTH_DOMAIN
            - XMPP_GUEST_DOMAIN
            - XMPP_MUC_DOMAIN
            - XMPP_INTERNAL_MUC_DOMAIN
            - XMPP_MODULES
            - XMPP_MUC_MODULES
            - XMPP_INTERNAL_MUC_MODULES
            - XMPP_RECORDER_DOMAIN
            - JICOFO_COMPONENT_SECRET
            - JICOFO_AUTH_USER
            - JICOFO_AUTH_PASSWORD
            - JVB_AUTH_USER
            - JVB_AUTH_PASSWORD
            - JIGASI_XMPP_USER
            - JIGASI_XMPP_PASSWORD
            - JIBRI_XMPP_USER
            - JIBRI_XMPP_PASSWORD
            - JIBRI_RECORDER_USER
            - JIBRI_RECORDER_PASSWORD
            - JWT_APP_ID
            - JWT_APP_SECRET
            - JWT_ACCEPTED_ISSUERS
            - JWT_ACCEPTED_AUDIENCES
            - JWT_ASAP_KEYSERVER
            - JWT_ALLOW_EMPTY
            - JWT_AUTH_TYPE
            - JWT_TOKEN_AUTH_MODULE
            - LOG_LEVEL
            - TZ
        networks:
            meet.jitsi:
                aliases:
                    - \${XMPP_SERVER}

    # Focus component
    jicofo:
        image: jitsi/jicofo
        restart: unless-stopped
        volumes:
            - \${CONFIG}/jicofo:/config
        environment:
            - ENABLE_AUTH
            - XMPP_DOMAIN
            - XMPP_AUTH_DOMAIN
            - XMPP_INTERNAL_MUC_DOMAIN
            - XMPP_SERVER
            - JICOFO_COMPONENT_SECRET
            - JICOFO_AUTH_USER
            - JICOFO_AUTH_PASSWORD
            - JICOFO_RESERVATION_REST_BASE_URL
            - JVB_BREWERY_MUC
            - JIGASI_BREWERY_MUC
            - JIBRI_BREWERY_MUC
            - JIBRI_PENDING_TIMEOUT
            - TZ
        depends_on:
            - prosody
        networks:
            meet.jitsi:

    # Video bridge
    jvb:
        image: jitsi/jvb
        restart: unless-stopped
        ports:
            - '\${JVB_PORT}:\${JVB_PORT}/udp'
            - '\${JVB_TCP_PORT}:\${JVB_TCP_PORT}'
        volumes:
            - \${CONFIG}/jvb:/config
        environment:
            - DOCKER_HOST_ADDRESS
            - XMPP_AUTH_DOMAIN
            - XMPP_INTERNAL_MUC_DOMAIN
            - XMPP_SERVER
            - JVB_AUTH_USER
            - JVB_AUTH_PASSWORD
            - JVB_BREWERY_MUC
            - JVB_PORT
            - JVB_TCP_HARVESTER_DISABLED
            - JVB_TCP_PORT
            - JVB_STUN_SERVERS
            - JVB_ENABLE_APIS
            - TZ
        depends_on:
            - prosody
        networks:
            meet.jitsi:

# Custom network so all services can communicate using a FQDN
networks:
    meet.jitsi:
EOF


# move to /opt
$prefix mv /tmp/docker-jitsi-meet /opt/docker-jitsi-meet
$prefix chown -R team-urgence /opt/docker-jitsi-meet

cd
sudo -u team-urgence bash -c "cd /opt/docker-jitsi-meet/ && docker-compose up -d"

## make nginx config
cat 1> /tmp/jitsi.conf <<EOF
server {
    listen 80;
    server_name meet.${IP}.xip.io;
    return 301 https://\$host\$request_uri;
}

server {
    server_name meet.${IP}.xip.io;
    listen 443 ssl;
    ssl_certificate /etc/ssl/certs/ssl-cert-snakeoil.pem;
    ssl_certificate_key /etc/ssl/private/ssl-cert-snakeoil.key;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

}
EOF

cd 
$prefix mv /tmp/jitsi.conf /etc/nginx/sites-available/jitsi.conf
$prefix ln -sf /etc/nginx/sites-available/jitsi.conf /etc/nginx/sites-enabled/jitsi.conf
$prefix nginx -s reload

cat <<EOF
You can now visit:
- https://meet.${IP}.xip.io to use meet jitsi for video conferences
- https://chat.${IP}.xip.io to use mattermost and configure your team chat
EOF
