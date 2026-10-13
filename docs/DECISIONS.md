# Décisions

## 2026-10-09 · Accent bleu pastel

**Décision.** La famille visuelle principale passe du pastel forêt au bleu pastel froid : fond bleu-gris très léger, accent bleu poudre, encre bleu ardoise.

**Pourquoi.** Le bleu correspond mieux à un outil de connexion et de transfert, tout en gardant la douceur, le contraste mesuré et la sobriété de Rushes. Les signaux d'erreur et d'attention restent indépendants de l'accent.

## 2026-10-09 · Socle SwiftPM sans dépendance

**Décision.** Le premier socle utilise uniquement les frameworks Apple disponibles et SwiftPM, sans bibliothèque réseau tierce.

**Pourquoi.** La performance, le modèle de sécurité et les licences des bibliothèques FTP/SFTP doivent être mesurés avant d'être figés. Les protocoles sont donc abstraits dès maintenant, sans prétendre que les adaptateurs sont déjà implémentés.

## 2026-10-09 · Nom de travail : Fil

**Décision.** Le produit s'appelle Fil dans le code jusqu'à décision contraire.

**Pourquoi.** Nom court, français, lié au lien entre l'utilisateur et ses fichiers. Le nom peut être remplacé sans modifier le modèle réseau.

## 2026-10-09 · kDrive via WebDAV en premier

**Décision.** `KDriveProvider` ne sera spécialisé qu'après validation des limites WebDAV de kDrive.

**Pourquoi.** Cela réduit le code spécifique et permet de livrer kDrive avec le même moteur que les autres serveurs WebDAV. Une API native ne sera justifiée que par une fonction indisponible ou une différence de performance mesurée.

## 2026-10-09 · Proton Drive derrière un adaptateur de processus

**Décision.** L'intégration Proton Drive commence par un fournisseur qui encapsule le CLI officiel, avec détection et diagnostic explicites.

**Pourquoi.** Le CLI est la surface publique annoncée par Proton, mais sa stabilité et ses capacités doivent être vérifiées avant d'en faire une dépendance de compilation. L'adaptateur pourra être remplacé par une API native sans contaminer les vues.

## 2026-10-12 · FTP et FTPS par la libcurl de macOS

**Décision.** FTP et FTPS passent par la libcurl livrée avec macOS, via la cible C minimale `CCurl` (`Sources/CCurl/`), enveloppée par [`CurlHandle`](../Sources/Fil/Transfer/FTP/Curl.swift) et [`FTPProvider`](../Sources/Fil/Transfer/FTP/FTPProvider.swift). FTPS explicite (`AUTH TLS`) sur tout port sauf 990, implicite sur 990. `MLSD` d'abord, repli définitif sur `LIST` (Unix et IIS) si le serveur le refuse.

**Pourquoi.** Network.framework ne sait pas passer une connexion existante en TLS (`AUTH TLS`) ni réutiliser la session TLS du canal de contrôle sur le canal de données, ce que vsftpd et ProFTPD exigent par défaut. libcurl le fait, gère passif/EPSV, et fait partie du système : rien n'est embarqué, aucune licence à suivre. Le benchmark « bibliothèque C contre Swift pur » prévu dans `RESTART.md` est tranché par cette impossibilité technique, pas par la vitesse.

## 2026-10-12 · SFTP par OpenSSH et un protocole SFTP écrit en Swift

**Décision.** [`SFTPProvider`](../Sources/Fil/Transfer/SFTP/SFTPProvider.swift) lance `/usr/bin/ssh -s … sftp` et parle lui-même le protocole SFTP version 3 ([`SFTPPacket.swift`](../Sources/Fil/Transfer/SFTP/SFTPPacket.swift), [`SFTPChannel`](../Sources/Fil/Transfer/SFTP/SFTPChannel.swift)). Lectures et écritures sont pipelinées (64 blocs de 32 Kio en vol). Le canal se rouvre seul s'il est tombé.

**Pourquoi.** Aucune bibliothèque SSH à embarquer ni à auditer. L'utilisateur garde ses clés, son agent, `~/.ssh/config` (alias, `ProxyJump`) et son `known_hosts`. Parler SFTP soi-même plutôt que piloter le client `sftp` donne des listings exacts (attributs binaires, pas de texte à deviner), la progression et l'annulation. Limite connue : incompatible avec la sandbox App Store en l'état.

## 2026-10-12 · Mot de passe SSH par `SSH_ASKPASS` et le Keychain

**Décision.** Fil sert d'assistant `SSH_ASKPASS` : `ssh` relance le binaire de Fil avec la question en argument, et [`Askpass`](../Sources/Fil/Transfer/SFTP/SSHCommand.swift) relit le mot de passe dans le Keychain d'après l'identifiant de connexion (`FIL_ASKPASS_CONNECTION`). Seules les questions de mot de passe ou de phrase de passe reçoivent une réponse ; toute autre question est refusée.

**Pourquoi.** Le secret ne passe ni par les arguments (visibles dans `ps`), ni par l'environnement, ni par un fichier. Il reste dans le Keychain, conformément à la règle des secrets. Vérifié de bout en bout avec une clé protégée par phrase de passe.

## 2026-10-12 · Empreintes SSH : mémorisées à la première connexion, refusées si elles changent

**Décision.** `StrictHostKeyChecking=accept-new` ([`SSHCommand.arguments`](../Sources/Fil/Transfer/SFTP/SSHCommand.swift)). Une empreinte changée bloque la connexion avec une raison lisible ([`ProviderError.hostKeyChanged`](../Sources/Fil/Transfer/RemoteFileProvider.swift)).

**Pourquoi.** Sans terminal, `ssh` ne peut pas demander de confirmation ; refuser toute première connexion rendrait SFTP inutilisable. `accept-new` protège contre l'usurpation après la première rencontre, ce que font la plupart des clients graphiques. Afficher l'empreinte avant de l'accepter est dans `NEXT.md`.

## 2026-10-12 · Certificats : la seule validation de macOS, sans exception

**Décision.** FTPS et WebDAV refusent tout certificat que macOS ne reconnaît pas ([`ProviderError.certificateUntrusted`](../Sources/Fil/Transfer/RemoteFileProvider.swift)). WebDAV ne parle que HTTPS. Aucune case « faire confiance quand même ».

**Pourquoi.** Une exception silencieuse expose le mot de passe au premier intermédiaire venu. L'épinglage explicite d'un certificat auto-signé (NAS) est prévu dans `NEXT.md`, avec confirmation de l'empreinte.

## 2026-10-12 · Contrat `RemoteFileProvider` révisé

**Décision.** [`RemoteFileProvider`](../Sources/Fil/Transfer/RemoteFileProvider.swift) : `connect()` renvoie le dossier de départ, `download` et `upload` rendent compte de la progression, `makeDirectory` est ajouté, `delete` est récursif pour un dossier. L'annulation passe par l'annulation de la tâche Swift. Un lien symbolique n'est jamais suivi pour supprimer ni pour parcourir ([`RemoteFile.isSymbolicLink`](../Sources/Fil/Model/Remote.swift)).

**Pourquoi.** L'interface a besoin de savoir où commencer, de montrer une progression et de créer des dossiers. Suivre un lien lors d'une suppression récursive effacerait le contenu de sa cible : le risque est trop grave pour être laissé à chaque fournisseur.

## 2026-10-12 · Une page par phase, les transferts à côté

**Décision.** [`Phase`](../Sources/Fil/Model/Phase.swift) remplace `ConnectionPhase` : `choosing`, `connecting`, `browsing`, `failed`. L'échec s'affiche sur la page de réglage, avec la raison au-dessus du bouton, pour corriger sans détour. Les transferts ne sont pas une phase : ils vivent dans un plateau visible partout ([`TransferQueue`](../Sources/Fil/Transfer/TransferQueue.swift)), continuent après « Fermer la connexion » et après la fermeture de la fenêtre. Quitter avec des transferts en cours demande confirmation.

**Pourquoi.** À 3 h du matin : choisir, voir, lancer, fermer la fenêtre. Le transfert ne doit pas retenir l'utilisateur sur une page.

## 2026-10-12 · Favoris versionnés

**Décision.** [`ConnectionStore`](../Sources/Fil/Model/ConnectionStore.swift) écrit une enveloppe versionnée (`fil.favorites`, version 2) avec la dernière connexion utilisée, présélectionnée au lancement. La version 1 (`fil.connections.v1`, tableau nu) est migrée une fois puis effacée. Le décodage tolère les champs absents.

**Pourquoi.** Pouvoir faire évoluer le format sans perdre les favoris existants.

## 2026-10-12 · Noms envoyés en Unicode composé (NFC)

**Décision.** Les noms de fichiers envoyés au serveur sont normalisés en NFC ([`LocalNaming.remoteName`](../Sources/Fil/Transfer/LocalNaming.swift)).

**Pourquoi.** macOS fournit des noms décomposés (`e` + accent). Un serveur Linux les conserve tels quels et affiche alors deux « été » différents. Constaté dans les journaux du serveur WebDAV de test.

## 2026-10-12 · Jetons visuels complétés

**Décision.** Ajout de [`TypeScale`](../Sources/Fil/Design/TypeScale.swift), [`Radius` et `Spacing`](../Sources/Fil/Design/Radius.swift), et dans [`Palette`](../Sources/Fil/Design/Palette.swift) de `accentWash`, `alertWash` et `caution` (avertissement « FTP non chiffré », ni alarme ni accent). `alert` devient adaptatif : même teinte en clair, plus lisible en sombre.

**Pourquoi.** `CLAUDE.md` annonçait `TypeScale` et `Radius` sans qu'ils existent ; les vues codaient les tailles en dur.

## 2026-10-12 · Paquet .app de développement

**Décision.** [`Support/Info.plist`](../Support/Info.plist) et `Tools/bundle.sh` produisent un `Fil.app` signé ad hoc, identifiant provisoire `com.fil.app`. `swift run Fil` reste la voie normale de développement.

**Pourquoi.** Un exécutable nu n'a ni icône de Dock stable, ni identité pour le trousseau, ni identifiant pour les outils d'accessibilité. L'identifiant définitif sera fixé avant toute distribution.

## 2026-10-12 · Proton Drive affiché mais bloqué

**Décision.** Proton Drive reste dans la liste, marqué « bientôt », et la connexion est bloquée avec une raison lisible ([`RemoteProtocol.unavailableReason`](../Sources/Fil/Model/Remote.swift)).

**Pourquoi.** Aucun faux transfert présenté comme réel. Le CLI officiel doit être validé avant d'écrire l'adaptateur.

## 2026-10-12 · Serveurs de test locaux

**Décision.** `Tools/test-servers.sh` lance sshd (non root), l'Apache de macOS avec mod_dav et pyftpdlib (FTP, FTP sans MLSD, FTPS) dans le dossier temporaire de l'utilisateur (`$TMPDIR/fil-test-servers`, hors de `.build` que `swift package clean` efface). pyftpdlib est installé dans un environnement Python isolé, jamais dans le système ni dans l'application. `Tools/integration-tests.sh` les lance, exécute `IntegrationTests` et les arrête.

**Pourquoi.** Les fournisseurs ne sont crédibles qu'éprouvés contre de vrais serveurs, erreurs comprises. Sans ces serveurs, les tests d'intégration sont ignorés : `swift test` reste rapide et autonome.
