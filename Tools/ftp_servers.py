"""Serveurs FTP de test : FTP complet, FTP sans MLSD (comme vsftpd) et FTPS explicite.

Usage : ftp_servers.py <dossier> <utilisateur> <mot de passe> <port ftp> <port sans mlsd> <port ftps>
"""
import os
import sys

from pyftpdlib.authorizers import DummyAuthorizer
from pyftpdlib.handlers import FTPHandler, TLS_FTPHandler
from pyftpdlib.servers import FTPServer


def main() -> None:
    state, user, password, ftp_port, legacy_port, ftps_port = sys.argv[1:7]
    home = os.path.join(state, "ftp")
    os.makedirs(home, exist_ok=True)

    authorizer = DummyAuthorizer()
    authorizer.add_user(user, password, home, perm="elradfmwMT")

    class Plain(FTPHandler):
        pass

    class Legacy(FTPHandler):
        proto_cmds = {k: v for k, v in FTPHandler.proto_cmds.items() if k not in ("MLSD", "MLST")}

    class Secure(TLS_FTPHandler):
        certfile = os.path.join(state, "ftps-cert.pem")
        keyfile = os.path.join(state, "ftps-key.pem")
        tls_control_required = True
        tls_data_required = True

    # Les trois serveurs partagent la boucle d'événements par défaut : une seule la fait tourner.
    servers = []
    for handler, port in ((Plain, ftp_port), (Legacy, legacy_port), (Secure, ftps_port)):
        handler.authorizer = authorizer
        handler.passive_ports = range(60000, 60200)
        servers.append(FTPServer(("127.0.0.1", int(port)), handler))
    servers[0].serve_forever()


if __name__ == "__main__":
    main()
