# Reprendre le travail

Ce document est destiné au prochain modèle ou développeur.

## État actuel (13 octobre 2026)

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
- Les envois sont atomiques (`nom.filpart` puis renommage) et « Réessayer » reprend un transfert interrompu, dans la session. Voir `DECISIONS.md` (13 octobre) pour les garde-fous : on ne reprend que ce que Fil a écrit lui-même.
- Un serveur FTP qui accepte aussi FTPS se voit proposer le passage, sur la page fichiers (`FTPSProbe`).
- Un serveur SSH ou un certificat inconnu ne passe plus en silence : une page montre l'empreinte et attend l'accord (`Phase.confirming`, `TrustView`). Ce qui est approuvé vit dans `~/Library/Application Support/Fil`, jamais dans `~/.ssh`.
- « Modifier » (⌘E) ouvre un fichier distant dans l'éditeur et renvoie chaque enregistrement (`EditCoordinator`), avec détection de conflit.
- Décisions des 12 et 13 octobre dans `DECISIONS.md` ; travail restant dans `NEXT.md`.
- Une application iPhone et iPad (18 octobre) vit dans `iOS/` : WebDAV et kDrive, même modèle que le Mac, pages propres. Elle n'a encore jamais été compilée : voir `NEXT.md`, section iOS.

## Commandes de vérification

```sh
swift build
swift test                      # 189 tests ; les 21 d'intégration sont ignorés sans serveurs
Tools/integration-tests.sh      # lance les serveurs locaux, exécute les 21 tests d'intégration, arrête tout
swift run Fil
Tools/bundle.sh                 # .build/Fil.app, signé ad hoc
```

`Tools/test-servers.sh start|stop` lance ou arrête seuls les serveurs (SFTP 2222, WebDAV 8088, WebDAV HTTPS 8443, FTP 2121, FTP sans MLSD 2122, FTPS 2990) ; les variables sont dans `$TMPDIR/fil-test-servers/env` (hors de `.build`, que `swift package clean` efface).

## Prochaine tranche recommandée

1. Un geste explicite pour remplacer une clé SSH ou un certificat qui a légitimement changé.
2. Renommer et déplacer dans l'interface (les fournisseurs savent déjà `move`).
3. Proton Drive par le CLI officiel, après vérification de sa surface.
4. File de transferts persistante, et la reprise entre deux sessions qui va avec.

## Pièges connus

- `sshd` se relance depuis `/` : dans `Tools/test-servers.sh`, tous ses chemins doivent être absolus.
- `swift package clean` efface tout `.build/` : l'état des serveurs de test vit donc dans `$TMPDIR`, et `stop` reconnaît aussi les serveurs à leur ligne de commande. Il efface aussi `.build/Fil.app` : relancer `Tools/bundle.sh`.
- Les trois serveurs pyftpdlib partagent une boucle d'événements : un seul `serve_forever`.
- libcurl, en reprise d'envoi, ne saute pas le début de la source : il faut positionner la lecture soi-même, sinon la taille est juste et le contenu faux (`FTPProvider.upload`).
- L'adresse d'un fichier WebDAV n'a pas de `/` final (Apache répond 400) ; celle d'un dossier en a un.
- `expectedContentLength` d'URLSession vaut -1 pour un `HEAD` sur un fichier vide : lire l'en-tête `Content-Length`.
- Dans le journal du serveur simulé, un fichier envoyé laisse deux traces (envoi, renommage).
- Pour Swift, `\r\n` est un seul caractère : `hasSuffix("\n")` est faux sur une ligne FTP. Comparer les octets (`CertificateReader.isCompleteReply`).
- `ssh` garde la **première** valeur d'une option : les options de la connexion d'essai (`discoveryArguments`) doivent précéder toutes les autres.
- Un `ScrollView` n'est pas rendu par `ImageRenderer` : `TrustView.page` en est séparé pour pouvoir être contrôlé hors écran.
- Apache sans root, avec deux ports d'écoute, demande `Mutex file:<dossier>` ; les guillemets ne sont pas interprétés dans cet argument.
- Swift compare les chaînes à équivalence canonique près : pour vérifier une normalisation Unicode, comparer les octets UTF-8.
- Le délégué par tâche d'URLSession ne reçoit pas la progression des téléchargements : elle passe par le délégué de session (`WebDAVSessionRelay`).
- Chaque recompilation change la signature ad hoc : macOS redemande l'accès aux mots de passe enregistrés par une version précédente.

Ne pas modifier les jetons de `Palette.swift` au niveau d'une vue. Ajouter une décision dans `docs/DECISIONS.md` avant un choix architectural.
