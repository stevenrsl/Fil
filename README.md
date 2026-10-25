# Fil

Client macOS de transferts distants, pensé pour être plus direct, calme et rapide que Cyberduck : choisir une connexion, voir les fichiers, lancer un transfert, fermer la fenêtre.

> **V0.** Utilisable, mais jeune. Les envois sont atomiques (le fichier en ligne n'est jamais écrit à moitié) et « Réessayer » reprend un transfert interrompu ; en revanche la file ne survit pas à la fermeture de l'application. Voir [docs/NEXT.md](docs/NEXT.md).

## Protocoles

| Protocole | État | Moteur |
| --- | --- | --- |
| FTP | fonctionnel | libcurl de macOS |
| FTPS | fonctionnel (explicite ; implicite sur le port 990) | libcurl de macOS |
| SFTP | fonctionnel (clés, agent, `~/.ssh/config`, mot de passe via le trousseau) | `ssh` de macOS + protocole SFTP v3 en Swift |
| WebDAV | fonctionnel, HTTPS seulement | URLSession |
| kDrive | via WebDAV, pas encore éprouvé sur un vrai kDrive | URLSession |
| Proton Drive | CLI officiel téléchargé et vérifié à la première utilisation | Proton Drive CLI |

Un serveur SSH ou un certificat inconnu n'est jamais accepté en silence : Fil montre l'empreinte et attend ton accord. « Modifier » ouvre un fichier distant dans ton éditeur et renvoie chaque enregistrement, en s'arrêtant si le serveur a changé entre-temps.

Aucune bibliothèque tierce n'est embarquée. Les mots de passe vont dans le Keychain, jamais dans les favoris ni dans les journaux. Aucun appel réseau de télémétrie.

## Construire

Prérequis : macOS 14 ou plus récent, Xcode ou les Command Line Tools (Swift 6).

```sh
swift build
swift test
swift run Fil
```

Pour une vraie application dans le Dock, signée ad hoc :

```sh
Tools/bundle.sh
open .build/Fil.app
```

Les tests d'intégration lancent des serveurs locaux (SFTP, WebDAV, FTP, FTPS) et vérifient un aller-retour complet sur chacun. Sans ces serveurs, ils sont ignorés par `swift test`.

```sh
Tools/integration-tests.sh
```

## Documentation

- [docs/DECISIONS.md](docs/DECISIONS.md) : les choix d'architecture et leurs raisons.
- [docs/PROTOCOLS.md](docs/PROTOCOLS.md) : la stratégie par protocole.
- [docs/RESTART.md](docs/RESTART.md) : l'état actuel et par où reprendre.
- [docs/NEXT.md](docs/NEXT.md) : ce qui reste à faire.
- [docs/TESTEURS.md](docs/TESTEURS.md) : guide pour essayer Fil.
- [Support/DISTRIBUTION.md](Support/DISTRIBUTION.md) : signature et distribution.

L'interface est en français pour l'instant.

## Licence

[MIT](LICENSE)
