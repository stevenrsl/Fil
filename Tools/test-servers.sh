#!/bin/zsh
# Serveurs locaux pour les tests d'intégration : SFTP (sshd non root), WebDAV (Apache de macOS),
# FTP, FTP sans MLSD et FTPS explicite (pyftpdlib dans un environnement Python isolé).
# Rien n'est installé dans le système ; tout vit dans le dossier d'état, reconstructible.
# Ce dossier est hors de .build : `swift package clean` l'effacerait sans arrêter les serveurs.
#
#   Tools/test-servers.sh start   # lance tout, écrit $FIL_TEST_SERVERS/env
#   Tools/test-servers.sh stop    # arrête tout
set -euo pipefail

ROOT="${0:A:h:h}"
STATE="${FIL_TEST_SERVERS:-${${TMPDIR:-/tmp}%/}/fil-test-servers}"
STATE="${STATE%/}"
SFTP_PORT=2222
WEBDAV_PORT=8088
WEBDAVS_PORT=8443
FTP_PORT=2121
FTP_LEGACY_PORT=2122
FTPS_PORT=2990
USER_NAME=fil
PASSWORD=fil-secret

PORTS=($SFTP_PORT $WEBDAV_PORT $WEBDAVS_PORT $FTP_PORT $FTP_LEGACY_PORT $FTPS_PORT)

stop() {
  for pidfile in "$STATE"/*.pid(N); do
    kill "$(cat "$pidfile")" 2>/dev/null || true
    rm -f "$pidfile"
  done
  # Filet : un serveur dont le fichier PID a disparu se reconnaît à sa ligne de commande.
  pkill -f "$STATE/sshd_config" 2>/dev/null || true
  pkill -f "$STATE/httpd.conf" 2>/dev/null || true
  pkill -f "ftp_servers.py $STATE" 2>/dev/null || true
  for port in $PORTS; do
    for _ in {1..50}; do
      nc -z 127.0.0.1 "$port" 2>/dev/null || break
      sleep 0.1
    done
  done
}

wait_port() {
  for _ in {1..50}; do
    nc -z 127.0.0.1 "$1" 2>/dev/null && return 0
    sleep 0.1
  done
  echo "Le port $1 ne répond pas. Journaux : $STATE" >&2
  return 1
}

start() {
  stop
  mkdir -p "$STATE"/{sftp,webdav,ftp}
  cd "$STATE"

  # SFTP : sshd non root, clé dédiée, aucun mot de passe.
  [[ -f host_ed25519 ]] || ssh-keygen -q -t ed25519 -N "" -f host_ed25519
  [[ -f client_ed25519 ]] || ssh-keygen -q -t ed25519 -N "" -f client_ed25519
  [[ -f other_ed25519 ]] || ssh-keygen -q -t ed25519 -N "" -f other_ed25519
  cp client_ed25519.pub authorized_keys
  echo "[127.0.0.1]:$SFTP_PORT $(cut -d' ' -f1,2 host_ed25519.pub)" > known_hosts
  echo "[127.0.0.1]:$SFTP_PORT $(cut -d' ' -f1,2 other_ed25519.pub)" > wrong_known_hosts
  cat > sshd_config <<EOF
Port $SFTP_PORT
ListenAddress 127.0.0.1
HostKey $STATE/host_ed25519
PidFile $STATE/sshd.pid
AuthorizedKeysFile $STATE/authorized_keys
StrictModes no
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
Subsystem sftp /usr/libexec/sftp-server
EOF
  # sshd se relance depuis / : tous les chemins doivent être absolus.
  /usr/sbin/sshd -f "$STATE/sshd_config" -E "$STATE/sshd.log"

  # Certificats auto-signés : FTPS (plus bas), WebDAV HTTPS, et un autre qui ne correspond à aucun serveur.
  for name in webdav other; do
    [[ -f $name-cert.pem ]] || openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
        -keyout $name-key.pem -out $name-cert.pem -subj "/CN=127.0.0.1" \
        -addext "subjectAltName=IP:127.0.0.1,DNS:localhost" 2>/dev/null
  done

  # WebDAV : Apache livré avec macOS, sur un port haut (HTTP et HTTPS).
  htpasswd -bc htpasswd "$USER_NAME" "$PASSWORD" 2>/dev/null
  cat > httpd.conf <<EOF
ServerRoot "/usr"
ServerName 127.0.0.1
Listen 127.0.0.1:$WEBDAV_PORT
PidFile "$STATE/httpd.pid"
# Avec deux ports d'écoute (HTTP et HTTPS), Apache a besoin d'un verrou d'acceptation ; sans root, il le met ici.
Mutex file:$STATE default
LoadModule mpm_prefork_module libexec/apache2/mod_mpm_prefork.so
LoadModule unixd_module libexec/apache2/mod_unixd.so
LoadModule authn_core_module libexec/apache2/mod_authn_core.so
LoadModule authn_file_module libexec/apache2/mod_authn_file.so
LoadModule authz_core_module libexec/apache2/mod_authz_core.so
LoadModule authz_user_module libexec/apache2/mod_authz_user.so
LoadModule auth_basic_module libexec/apache2/mod_auth_basic.so
LoadModule alias_module libexec/apache2/mod_alias.so
LoadModule dav_module libexec/apache2/mod_dav.so
LoadModule dav_fs_module libexec/apache2/mod_dav_fs.so
LoadModule log_config_module libexec/apache2/mod_log_config.so
LoadModule ssl_module libexec/apache2/mod_ssl.so
LoadModule socache_shmcb_module libexec/apache2/mod_socache_shmcb.so
Listen 127.0.0.1:$WEBDAVS_PORT
SSLSessionCache "shmcb:$STATE/ssl_scache(512000)"
<VirtualHost 127.0.0.1:$WEBDAVS_PORT>
  SSLEngine on
  SSLCertificateFile "$STATE/webdav-cert.pem"
  SSLCertificateKeyFile "$STATE/webdav-key.pem"
</VirtualHost>
ErrorLog "$STATE/httpd-error.log"
LogFormat "%h %u \"%r\" %>s" simple
CustomLog "$STATE/httpd-access.log" simple
DavLockDB "$STATE/davlock"
Alias /dav "$STATE/webdav"
<Directory "$STATE/webdav">
  Dav On
  AuthType Basic
  AuthName "Fil"
  AuthUserFile "$STATE/htpasswd"
  Require valid-user
</Directory>
EOF
  /usr/sbin/httpd -f "$STATE/httpd.conf"

  # FTP, FTP sans MLSD, FTPS explicite avec un certificat auto-signé.
  if [[ ! -x venv/bin/python ]]; then
    python3 -m venv venv
    venv/bin/pip install -q pyftpdlib pyopenssl
  fi
  [[ -f ftps-cert.pem ]] || openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
      -keyout ftps-key.pem -out ftps-cert.pem -subj "/CN=127.0.0.1" \
      -addext "subjectAltName=IP:127.0.0.1,DNS:localhost" 2>/dev/null
  cp "$ROOT/Tools/ftp_servers.py" ftp_servers.py
  venv/bin/python -I ftp_servers.py "$STATE" "$USER_NAME" "$PASSWORD" $FTP_PORT $FTP_LEGACY_PORT $FTPS_PORT > ftp.log 2>&1 &
  echo $! > ftp.pid

  for port in $PORTS; do wait_port $port; done

  sha256() { openssl x509 -in "$1" -noout -fingerprint -sha256 | sed 's/.*=//; s/://g' | tr 'A-F' 'a-f'; }
  cat > env <<EOF
FIL_IT_USER=$USER_NAME
FIL_IT_PASSWORD=$PASSWORD
FIL_IT_FTP_PORT=$FTP_PORT
FIL_IT_FTP_LEGACY_PORT=$FTP_LEGACY_PORT
FIL_IT_FTPS_PORT=$FTPS_PORT
FIL_IT_FTPS_CA=$STATE/ftps-cert.pem
FIL_IT_FTPS_SHA256=$(sha256 ftps-cert.pem)
FIL_IT_OTHER_CERT=$STATE/other-cert.pem
FIL_IT_SFTP_PORT=$SFTP_PORT
FIL_IT_SFTP_USER=$(whoami)
FIL_IT_SFTP_KEY=$STATE/client_ed25519
FIL_IT_SFTP_FINGERPRINT=$(ssh-keygen -lf host_ed25519.pub | awk '{print $2}')
FIL_IT_SFTP_KNOWN_HOSTS=$STATE/known_hosts
FIL_IT_SFTP_WRONG_KNOWN_HOSTS=$STATE/wrong_known_hosts
FIL_IT_WEBDAV_URL=http://127.0.0.1:$WEBDAV_PORT/dav
FIL_IT_WEBDAVS_URL=https://127.0.0.1:$WEBDAVS_PORT/dav
FIL_IT_WEBDAVS_SHA256=$(sha256 webdav-cert.pem)
EOF
  echo "Serveurs prêts. Variables : $STATE/env"
}

case "${1:-start}" in
  start) start ;;
  stop) stop; echo "Serveurs arrêtés." ;;
  *) echo "usage : $0 start|stop" >&2; exit 2 ;;
esac
