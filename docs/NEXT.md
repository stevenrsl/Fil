# Travaux non terminés

Ce qui manque, par ordre d'intérêt pour le moment d'usage (3 h du matin : choisir, voir, lancer, fermer).

## Transferts

- **Modification sur place hors de la file.** Les téléchargements et envois de l'éditeur (`EditCoordinator`) ne passent pas par `TransferQueue` : ils n'empêchent pas la veille, ne notifient pas et ne disent pas un blocage.
- **Notification de fin : vérifier à la main** depuis `Fil.app` (autorisation, son, clic qui ramène Fil). Couvert sans interface par un faux `TransferActivity`.
- **Transfert bloqué : proposer un geste.** Fil dit qu'un transfert n'avance plus, mais ne propose que « Annuler », qui efface le partiel. Un « Relancer » qui coupe et reprend depuis le partiel serait plus utile.
- **Reprise entre deux sessions.** « Réessayer » reprend, mais seulement tant que Fil est ouvert : la file et son registre vivent en mémoire, et les partiels locaux sont effacés à la fermeture. Reprendre au lancement demanderait un témoin fiable du contenu (empreinte ou ETag), faute de quoi on risque de compléter un fichier qui a changé.
- **Reprise d'un envoi WebDAV.** Un `PUT` repart du début ; seuls les téléchargements reprennent (`Range`). À étudier : les extensions de téléversement par morceaux de Nextcloud et d'Infomaniak.
- **Partiels distants après fermeture de Fil.** Un envoi en échec laisse `nom.filpart` sur le serveur ; « Effacer les terminés » le supprime, mais pas la fermeture de l'application, qui ne peut pas compter sur le réseau.
- **Détection d'un fichier distant réécrit à la même taille** entre deux essais d'un téléchargement repris : aujourd'hui seule la taille est comparée.
- **Modification sur place : sessions éphémères.** Les copies survivent une semaine dans `~/Library/Caches/Fil/Edits`, mais Fil ne les rattache pas à leur serveur au lancement suivant : reprendre une modification interrompue par un plantage se fait à la main.
- **Modification sur place : conflit sur un serveur à date grossière.** Un listing FTP sans `MLSD` donne la date à la minute ; deux écritures de même taille dans la même minute ne se distinguent pas.
- **Modification sur place : `.html` dans TextEdit** s'affiche en texte riche. Choisir un vrai éditeur dans les réglages.
- **Modification sur place : fichiers de plus de 64 Mo** refusés. Un éditeur n'en a pas l'usage, mais le seuil mérite d'être mesuré.
- **Glisser vers le Finder : vérifier à la main.** Le chemin de la promesse est testé sans interface (`NSItemProvider.loadFileRepresentation`), mais le geste réel (une ligne, plusieurs lignes, un dossier, annulation depuis le Finder) n'a pas été essayé à l'écran. Déposer une ligne sur la propre liste de Fil la télécharge avant de la refuser : à éviter dès que SwiftUI permet de reconnaître un glisser interne.
- **Dossiers liés.** Un lien symbolique vers un dossier n'est pas suivi pendant le téléchargement d'un dossier (protection contre les boucles). Proposer de le suivre avec une limite de profondeur.
- **Déplacer dans l'interface** (glisser une ligne sur un dossier). Le renommage existe (menu contextuel, ⇧⌘R) ; Entrée ouvre toujours, comme avant.
- **Renommer pendant un transfert** : refusé si le fichier est ouvert dans l'éditeur, pas s'il est en cours de téléchargement ou d'envoi, qui échouera alors avec « n'existe pas ».
- **Renommer un dossier en WebDAV** : `MOVE` part sans `/` final. Couvert par le faux fournisseur, pas encore contre un vrai serveur (kDrive, Nextcloud, serveur d'intégration).
- **Renommer : course avec un autre client.** Fil vérifie le nom dans le listing affiché ; un fichier créé ailleurs sous ce nom entre-temps serait remplacé par `move`.

## Sécurité

- **Clé SSH ou certificat qui a changé** : Fil refuse, sans issue dans l'interface. Prévoir un geste explicite (avec l'ancienne et la nouvelle empreinte côte à côte) pour remplacer l'approbation après un renouvellement légitime. Aujourd'hui : « Oublier » le certificat, ou supprimer la ligne du serveur dans `~/Library/Application Support/Fil/known_hosts`.
- **Certificat épinglé et hôte** : l'épinglage ne vérifie pas le nom du serveur, seulement le certificat. C'est voulu (un NAS joint par son adresse IP présente un certificat à un autre nom), mais on pourrait afficher un avertissement quand le nom ne correspond pas.
- **Rebond SSH (`ProxyJump`)** : plusieurs clés inconnues sont montrées ensemble, avec le champ « hôte » brut de `known_hosts` (qui peut être un condensé). À rendre lisible.
- **FTPS : la proposition reste muette si le certificat du serveur n'est pas reconnu.** On pourrait proposer l'épinglage plutôt que se taire.
- **FTPS implicite (port 990)** : la sonde de proposition ne teste que FTPS explicite.
- **WebDAV non chiffré** sur réseau local : décision à prendre. Aujourd'hui HTTPS seulement.
- **Sandbox** : `/usr/bin/ssh` n'est pas utilisable dans la sandbox App Store. À étudier seulement si une distribution App Store est envisagée.

## Protocoles

- **Proton Drive** via le CLI officiel : vérifier sa disponibilité, ses commandes, sa sortie machine et son authentification, puis écrire l'adaptateur de processus.
- **kDrive** : valider en conditions réelles (mot de passe d'application, limites de taille, débit). Passer à l'API seulement pour une fonction absente ou un écart de performance mesuré.
- **FTP actif** (`PORT`) : non proposé, seul le passif est utilisé. Ajouter une option si un serveur l'exige (`CURLOPT_FTPPORT`).
- **Clé SSH par connexion** : aujourd'hui les clés viennent de l'agent et de `~/.ssh/config`. Un champ « clé » éviterait de passer par la configuration.

## Tests

- **Mot de passe SSH en test automatique** : un sshd non root ne sait pas vérifier un mot de passe. Le chemin `SSH_ASKPASS` → Keychain a été vérifié de bout en bout avec une clé protégée par phrase de passe, mais pas dans `swift test`.
- **Tests d'interface** : aucun test automatisé des vues. Les modèles observables (`AppModel`, `BrowserModel`, `TransferQueue`) sont testés.
- **Mode sombre des nouvelles vues** (bannière FTPS, page de confirmation, lignes de modification) : rendu clair vérifié hors écran, rendu sombre non vérifié (le moteur de rendu hors écran n'a pas résolu les couleurs adaptatives).
- **Éditeur réel** : le lancement de l'éditeur (`EditorLauncher`) n'est pas couvert par les tests, qui injectent un faux ouvreur.
- **Proposition FTPS sur un vrai hébergeur** : validée contre un serveur local avec certificat de test, pas encore contre un serveur public (OVH, etc.).

## Application

- **Préférences séparées** : `swift run Fil` lit le domaine `Fil`, `Fil.app` lit `com.fil.app`. Les favoris ne sont donc pas partagés entre les deux. À unifier quand l'identifiant définitif sera choisi.
- Identifiant de bundle définitif, icône, signature Developer ID, notarisation (voir `Support/DISTRIBUTION.md`).
- Passe VoiceOver complète ; libellés d'accessibilité des actions du plateau déjà posés.
- Interface en anglais, après stabilisation des phrases françaises.
