# Reprendre le travail

Ce document est destiné au prochain modèle ou développeur.

## État actuel (12 octobre 2026)

Fil est utilisable : on choisit une connexion, on voit les fichiers, on télécharge et on envoie (fichiers et dossiers entiers), on ferme la fenêtre pendant que les transferts continuent.

| Protocole | État | Moteur |
| --- | --- | --- |
| FTP | fonctionnel, éprouvé contre pyftpdlib et un vrai serveur OVH | libcurl système (`Transfer/FTP/`) |
| FTPS | fonctionnel (explicite ; implicite sur 990) | libcurl système |
| SFTP | fonctionnel (clés, agent, `~/.ssh/config`, mot de passe via Keychain) | OpenSSH + protocole SFTP v3 en Swift (`Transfer/SFTP/`) |
| WebDAV | fonctionnel en HTTPS | URLSession (`Transfer/WebDAV/`) |
| kDrive | via WebDAV ; identifiant numérique accepté | URLSession |
| Proton Drive | affiché, bloqué avec une raison | aucun |

- Modèle pur dans `Model/` : connexions, chemins, adresses collées, phases, readiness, format, élément de transfert.
- `App/AppModel` pilote les phases ; `App/BrowserModel` la page fichiers ; `Transfer/TransferQueue` la file (deux transferts à la fois).
- Les secrets passent par `SecretStore` (Keychain en production, mémoire dans les tests). Les favoris sont versionnés (`fil.favorites`, v2) et migrent depuis la v1.
- Jetons visuels dans `Design/` : `Palette`, `TypeScale`, `Radius`, `Spacing`, composants.
- Décisions du 12 octobre dans `DECISIONS.md` ; travail restant dans `NEXT.md`.

## Commandes de vérification

```sh
swift build
swift test                      # 95 tests ; les 12 d'intégration sont ignorés sans serveurs
Tools/integration-tests.sh      # lance les serveurs locaux, exécute les 12 tests d'intégration, arrête tout
swift run Fil
Tools/bundle.sh                 # .build/Fil.app, signé ad hoc
```

`Tools/test-servers.sh start|stop` lance ou arrête seuls les serveurs (SFTP 2222, WebDAV 8088, FTP 2121, FTP sans MLSD 2122, FTPS 2990) ; les variables sont dans `$TMPDIR/fil-test-servers/env` (hors de `.build`, que `swift package clean` efface).

## Prochaine tranche recommandée

1. Reprise des transferts interrompus (`.filpart` conservé, `REST` / décalage / `Range`).
2. Confirmation de l'empreinte SSH à la première connexion, épinglage des certificats auto-signés.
3. Proton Drive par le CLI officiel, après vérification de sa surface.
4. File de transferts persistante.

## Pièges connus

- `sshd` se relance depuis `/` : dans `Tools/test-servers.sh`, tous ses chemins doivent être absolus.
- `swift package clean` efface tout `.build/` : l'état des serveurs de test vit donc dans `$TMPDIR`, et `stop` reconnaît aussi les serveurs à leur ligne de commande. Il efface aussi `.build/Fil.app` : relancer `Tools/bundle.sh`.
- Les trois serveurs pyftpdlib partagent une boucle d'événements : un seul `serve_forever`.
- Swift compare les chaînes à équivalence canonique près : pour vérifier une normalisation Unicode, comparer les octets UTF-8.
- Le délégué par tâche d'URLSession ne reçoit pas la progression des téléchargements : elle passe par le délégué de session (`WebDAVSessionRelay`).
- Chaque recompilation change la signature ad hoc : macOS redemande l'accès aux mots de passe enregistrés par une version précédente.

Ne pas modifier les jetons de `Palette.swift` au niveau d'une vue. Ajouter une décision dans `docs/DECISIONS.md` avant un choix architectural.
