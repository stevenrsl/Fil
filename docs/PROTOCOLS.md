# Plan des protocoles

| Priorité | Protocole | Stratégie retenue | État | Risque restant |
| --- | --- | --- | --- | --- |
| 1 | FTP/FTPS | libcurl système, `MLSD` puis `LIST` | en place, testé | reprise partielle, mode actif, certificats auto-signés |
| 2 | SFTP | `ssh -s sftp` + protocole v3 en Swift | en place, testé | confirmation d'empreinte, sandbox |
| 3 | WebDAV | URLSession + XML, HTTPS seulement | en place, testé | serveurs aux réponses atypiques |
| 4 | kDrive | WebDAV d'abord | en place, non éprouvé sur kDrive réel | limites et authentification propres à kDrive |
| 5 | Proton Drive | processus CLI officiel | bloqué avec une raison | évolution du CLI, sandbox |

Tous les fournisseurs respectent `RemoteFileProvider`. Ils n'exposent aucun type de bibliothèque au modèle ni aux vues, traduisent leurs erreurs en `ProviderError` lisibles et s'annulent par l'annulation de la tâche Swift.

## Détails par protocole

**FTP/FTPS** (`Transfer/FTP/`). Une connexion libcurl réutilisée pour la navigation ; une connexion par transfert. Chemins absolus (`%2F`) et un seul `CWD` (`SINGLECWD`). Mode passif en ignorant l'adresse annoncée par le serveur (NAT). FTPS : explicite sauf sur le port 990.

**SFTP** (`Transfer/SFTP/`). Les options en ligne de commande priment sur `~/.ssh/config` ; le port 22 et l'utilisateur vide ne sont pas imposés, pour qu'un alias garde les siens. 64 requêtes de 32 Kio en vol. Les liens sont résolus par `STAT` pour savoir s'ils mènent à un dossier.

**WebDAV** (`Transfer/WebDAV/`). `PROPFIND` profondeur 1, espaces de noms traités, seules les propriétés en 2xx retenues. La racine WebDAV de la connexion est la limite de navigation. `DELETE` récursif natif, `MKCOL` pour les dossiers.
