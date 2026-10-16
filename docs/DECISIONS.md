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

## 2026-10-13 · Envoi atomique : nom temporaire puis renommage

**Décision.** Tout fichier envoyé arrive d'abord sous `nom.filpart` ([`RemotePath.partialSibling`](../Sources/Fil/Model/Remote.swift)) et n'est renommé qu'une fois complet ([`TransferRunner.uploadFile`](../Sources/Fil/Transfer/TransferRunner.swift)). Au-delà de 4 Mio, ou après une reprise, la taille reçue par le serveur est vérifiée avant de renommer ; en dessous, la réponse de fin de transfert du serveur suffit, pour ne pas ajouter des allers-retours à chaque petit fichier. Un renommage qui refuse d'écraser (certains serveurs FTP, SFTP sans `posix-rename`) passe par [`moveReplacing`](../Sources/Fil/Transfer/RemoteFileProvider.swift) : l'ancien fichier est mis de côté en `.filbak`, le nouveau prend sa place, puis l'ancien est supprimé ; si le nouveau ne peut pas être placé, l'ancien est rendu.

**Pourquoi.** Envoyer directement sous le nom final laissait, après une coupure, un `index.html` à moitié écrit servi tel quel aux visiteurs. Avec le nom temporaire, la version en ligne est l'ancienne ou la nouvelle entière, jamais un morceau.

**Repli.** Un compte qui refuse le renommage (dépôt seul) ferait échouer tous les envois. Fil le détecte, renvoie directement sous le nom final, l'indique dans le plateau (« envoi direct : ce serveur refuse le renommage ») et s'en souvient pour la session ([`UploadPolicy`](../Sources/Fil/Transfer/TransferRunner.swift)). Ce repli est non atomique, et le dit.

## 2026-10-13 · Reprise des transferts : dans la session, sur ce que Fil a écrit lui-même

**Décision.** « Réessayer » reprend où le transfert s'est arrêté, grâce à un registre par transfert ([`TransferLedger`](../Sources/Fil/Transfer/TransferLedger.swift)). Fil ne reprend **que** ce qu'il sait avoir écrit pendant cette session. Un envoi ne reprend que si la source locale n'a changé ni de taille ni de date ; un téléchargement que si la taille distante n'a pas bougé. Un `.filpart` inconnu (autre session, autre outil) n'est jamais complété. Après une coupure (réseau, délai), le partiel est gardé ; après un refus du serveur ou une annulation, il est effacé. Les partiels locaux disparaissent à la fermeture de Fil. Un dossier repris réutilise son dossier local et saute les fichiers déjà terminés.

**Pourquoi.** Compléter un vieux `.filpart` du même nom, puis le publier par renommage, serait une corruption silencieuse : taille juste, contenu faux. La reprise est un gain de confort ; elle ne doit jamais coûter de l'intégrité. Limite connue : un fichier distant réécrit à la même taille entre deux essais n'est pas détecté (la taille est le seul témoin que FTP et SFTP donnent partout).

## 2026-10-13 · Contrat des fournisseurs : taille, renommage, décalage de reprise

**Décision.** [`RemoteFileProvider`](../Sources/Fil/Transfer/RemoteFileProvider.swift) gagne `size(of:)`, `move(_:to:)`, `canResumeUploads`, et un paramètre `resumingAt` sur `download` et `upload`. La progression est toujours comptée depuis le début du fichier, reprise comprise. Chaque protocole : FTP `SIZE` / `RNFR`+`RNTO` / `REST` et `APPE` ; SFTP `STAT` / `posix-rename@openssh.com` (repli `RENAME`) / lectures et écritures à décalage explicite ; WebDAV `HEAD` / `MOVE` avec `Overwrite: T` / `Range` (repli à zéro si le serveur répond 200 ou 416), sans reprise d'envoi puisqu'un `PUT` n'est pas reprenable.

**Pourquoi.** Le contrat porte seul ce que la logique de transfert doit pouvoir demander, sans qu'aucun type de bibliothèque ne le traverse.

## 2026-10-13 · Piège libcurl : une reprise d'envoi ne saute pas le début de la source

**Décision.** [`FTPProvider.upload`](../Sources/Fil/Transfer/FTP/FTPProvider.swift) positionne lui-même la lecture au décalage avant de lancer libcurl.

**Pourquoi.** Vérifié avec un programme C minimal contre un vrai serveur (libcurl 8.7) : en reprise, libcurl envoie `APPE` et retranche le décalage de la taille annoncée, mais lit la source depuis son début. Résultat : le fichier a la bonne taille et le mauvais contenu, sans aucune erreur. Le test d'intégration compare les octets pour ce motif précis.

## 2026-10-13 · Proposition de passer en FTPS

**Décision.** Une fois connecté en FTP, Fil sonde en arrière-plan, sur une connexion à part, si le serveur accepte FTPS ([`FTPSProbe`](../Sources/Fil/Transfer/FTP/FTPSProbe.swift)). Il propose le passage seulement si la connexion chiffrée s'ouvre, que macOS reconnaît le certificat **et** qu'un listing du dossier de départ passe. La proposition est une bannière sur la page fichiers, avec deux liens : « Passer en FTPS » (change le protocole, enregistre, rouvre) et « Ne plus proposer » (mémorisé par connexion, [`RemoteConnection.ftpsOfferDismissed`](../Sources/Fil/Model/Remote.swift)). Pas de sonde pour le port 990 ni pour un protocole autre que FTP.

**Pourquoi.** Le FTP simple envoie mot de passe et fichiers en clair. Proposer FTPS pour que la connexion suivante échoue serait pire que de se taire, d'où l'exigence du listing et du certificat valide. Un certificat non reconnu ne déclenche rien : le basculement échouerait.

**Limite assumée.** La connexion qui déclenche la sonde est déjà ouverte en clair : l'utilisateur a choisi FTP, Fil ne change pas de protocole à sa place ni ne retarde la connexion. La proposition protège les suivantes.

## 2026-10-13 · Les serveurs de test ne vivent plus dans `.build`

**Décision.** `Tools/test-servers.sh` garde son état dans `$TMPDIR/fil-test-servers` et sait arrêter des serveurs dont le fichier PID a disparu.

**Pourquoi.** `swift package clean` efface `.build/` sans arrêter les serveurs : ils restaient orphelins sur leurs ports.

## 2026-10-13 · Serveur SSH inconnu : on montre l'empreinte, on ne l'accepte plus en silence

**Décision.** `ssh` tourne en `StrictHostKeyChecking=yes` ([`SSHCommand.arguments`](../Sources/Fil/Transfer/SFTP/SSHCommand.swift)). Quand le serveur est inconnu, [`HostKeyDiscovery`](../Sources/Fil/Transfer/Trust/CertificateReader.swift) relève sa clé par une connexion d'essai vers un `known_hosts` jetable, avec `PreferredAuthentications=none` : aucun identifiant ne part. L'utilisateur voit l'empreinte sur une page à part ([`TrustView`](../Sources/Fil/Views/TrustView.swift), phase `Phase.confirming`) ; s'il accepte, la clé est écrite dans le fichier de Fil, puis la connexion se fait pour de bon, toujours en mode strict.

**Pourquoi.** `accept-new` mémorisait la première clé vue sans rien demander : c'est exactement le moment où une usurpation passe. La connexion d'essai passe par `ssh` lui-même, donc alias, `ProxyJump`, port et `~/.ssh/config` sont respectés, et la clé relevée est celle qu'il présentera ensuite. La clé enregistrée est celle dont l'empreinte a été affichée, pas une seconde lecture.

**Où vit la confiance.** Dans `~/Library/Application Support/Fil/known_hosts` ([`FilKnownHosts`](../Sources/Fil/Transfer/Trust/TrustStores.swift)), passé à `ssh` en `GlobalKnownHostsFile` : lu en plus de `~/.ssh/known_hosts`, jamais écrit par `ssh` (`UpdateHostKeys=no`). Fil n'écrit rien dans `~/.ssh`, et ce qu'il approuve s'efface en supprimant un fichier. Les serveurs déjà acceptés par l'ancien mode restent connus : leur clé est dans `~/.ssh/known_hosts`. Une clé qui **change** reste refusée, sans nouvelle question.

## 2026-10-13 · Certificats non reconnus : relevés, vérifiés par l'utilisateur, puis épinglés

**Décision.** Un certificat que macOS refuse n'est plus une impasse. FTPS : [`CertificateReader`](../Sources/Fil/Transfer/Trust/CertificateReader.swift) relève le certificat avec `URLSessionStreamTask.startSecureConnection()`, qui passe la connexion FTP en TLS sur place sans rien envoyer d'autre que `AUTH TLS`. WebDAV : le défi de confiance d'`URLSession` fournit le certificat. L'utilisateur voit nom, origine (auto-signé ou non), expiration et empreinte SHA-256 ; s'il accepte, le certificat est épinglé pour **cette connexion** ([`RemoteConnection.trustedCertificate`](../Sources/Fil/Model/Remote.swift), PEM dans `Application Support/Fil/certificates`). Fil ne se connecte alors qu'à ce certificat : FTPS le donne à libcurl comme unique autorité (`CURLOPT_CAINFO`, nom non vérifié), WebDAV compare son empreinte dans le défi. Un certificat différent est refusé avec « le certificat a changé » ([`ProviderError.certificateChanged`](../Sources/Fil/Transfer/RemoteFileProvider.swift)), sans nouvelle question.

**Pourquoi.** Un NAS ou un serveur personnel n'aura jamais de certificat reconnu par macOS ; refuser sans issue poussait à renoncer au chiffrement. Épingler un certificat vérifié à l'œil est plus sûr que « ne rien vérifier » et plus honnête que « tout accepter ». Le serveur FTPS de l'utilisateur change de certificat ? Le refus est volontaire : « Oublier » (réglages de la connexion) redemande la vérification.

**Garde-fous.** Changer l'adresse, le port ou le protocole d'une connexion oublie son certificat : la confiance ne suit pas un autre serveur. Le fichier PEM n'est supprimé que si plus aucune connexion ne l'utilise. Aucune case « faire confiance quand même » sans empreinte affichée.

## 2026-10-13 · Piège Swift : `\r\n` n'est pas `\n`

**Décision.** La fin d'une réponse FTP se détecte sur les octets ([`CertificateReader.isCompleteReply`](../Sources/Fil/Transfer/Trust/CertificateReader.swift)), pas avec `hasSuffix("\n")`.

**Pourquoi.** Pour Swift, `\r\n` est un seul caractère : `"a\r\n".hasSuffix("\n")` est faux. La lecture attendait une fin qui ne venait pas et abandonnait au bout de dix secondes. Trouvé par le test d'intégration FTPS ; couvert par un test de non-régression.

## 2026-10-13 · Modification sur place

**Décision.** « Modifier » (menu contextuel, ⌘E) télécharge le fichier dans `~/Library/Caches/Fil/Edits`, l'ouvre dans l'éditeur, surveille la copie et renvoie chaque enregistrement ([`EditCoordinator`](../Sources/Fil/App/EditCoordinator.swift)). Un enregistrement se reconnaît à une date ou une taille qui change, **vue deux fois de suite** (l'éditeur n'est pas envoyé à mi-écriture), puis à un contenu qui change vraiment (condensé SHA-256) : un fichier simplement « touché » n'envoie rien. Chaque envoi passe par le chemin atomique des transferts ([`TransferRunner.replaceFile`](../Sources/Fil/Transfer/TransferRunner.swift)) sous le nom exact du serveur, sans le renormaliser.

**Conflits.** Avant d'envoyer, Fil relit taille et date du fichier distant : si elles ne sont plus celles du téléchargement (ou si le fichier a disparu), rien n'est envoyé. L'utilisateur choisit « Écraser » ou « Abandonner ». La date posée par notre propre envoi devient la nouvelle référence : elle n'est pas un conflit.

**Pertes évitées.** La copie locale n'est jamais supprimée tant qu'elle porte des changements non envoyés : « Terminer » envoie d'abord un dernier enregistrement et garde la copie en cas de conflit ou d'échec ; quitter Fil avec des changements en attente demande confirmation et laisse les copies une semaine. Un échec n'est pas rejoué en boucle : un nouvel enregistrement, ou « Réessayer », relance. Un fichier déjà ouvert se rouvre au lieu de se dupliquer, parce que deux copies se disputeraient le même fichier. Limite : 64 Mo.

**Éditeur.** Réglable (Réglages › Modification). Sans choix, l'application que macOS associe au fichier, sauf si c'est un navigateur (un `.html` s'y afficherait au lieu de s'y modifier) : on prend alors l'éditeur de texte par défaut ([`EditorLauncher`](../Sources/Fil/App/EditorLauncher.swift)).
