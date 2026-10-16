# Guide testeurs

Merci de tester Fil. Ce qui compte : le temps entre « je veux ce fichier » et « je l'ai », et chaque moment où tu ne savais pas ce qui se passait.

## Lancer Fil

```sh
swift run Fil
```

Ou, pour une vraie application dans le Dock :

```sh
Tools/bundle.sh
open .build/Fil.app
```

## Parcours à essayer

1. **Ajouter une connexion** (⌘N). Colle une adresse complète dans le champ Adresse, par exemple `sftp://moi@exemple.fr:2222/var/www` : protocole, utilisateur, port et dossier se remplissent seuls.
2. **Se connecter** (Entrée ou double-clic sur la connexion dans la barre latérale). Le mot de passe part dans le trousseau de macOS ; le champ affiche ensuite « Enregistré dans le trousseau ».
3. **Naviguer** : double-clic sur un dossier, ⌘↑ pour remonter, le fil d'Ariane en haut est cliquable, ⌘R pour actualiser, le champ Filtrer pour réduire la liste.
4. **Télécharger** : sélectionne puis bouton « Télécharger » ou ⌘D, ou double-clic sur un fichier. Un dossier se télécharge en entier. Rien n'est jamais écrasé : un nom pris reçoit « (2) ».
5. **Envoyer** : glisse des fichiers ou des dossiers depuis le Finder sur la liste, ou « Envoyer… » (⌘U). Fil demande avant de remplacer un fichier existant.
6. **Fermer la fenêtre pendant un transfert** : il continue. Rouvre Fil depuis le Dock pour voir le plateau.
7. **Couper le réseau pendant un envoi ou un téléchargement** (Wi-Fi coupé, câble débranché), puis le rétablir et cliquer sur « Réessayer » dans le plateau. Le transfert doit reprendre là où il s'était arrêté (la phrase dit « Reprise à… »), pas repartir de zéro. Pendant la coupure, la version en ligne du fichier ne doit pas avoir changé : l'envoi se fait sous `nom.filpart` et n'est renommé qu'à la fin.
8. **Connexion FTP** : si le serveur accepte aussi FTPS, une bannière propose d'y passer. Essaie « Passer en FTPS » : la connexion se rouvre chiffrée. « Ne plus proposer » est mémorisé pour ce serveur.
9. **Première connexion à un serveur SFTP** : une page montre l'empreinte du serveur. Compare-la avec celle que ton hébergeur t'a donnée, puis « Faire confiance et se connecter ». Aux connexions suivantes, rien n'est redemandé ; si l'empreinte change, Fil refuse.
10. **Serveur avec un certificat auto-signé** (NAS, serveur personnel, en FTPS ou WebDAV) : la même page montre le certificat. Une fois approuvé, il apparaît dans les réglages de la connexion, avec « Oublier ».
11. **Modifier un fichier** : clic droit › « Modifier » (ou ⌘E). Le fichier s'ouvre dans ton éditeur ; chaque enregistrement part au serveur, et le plateau dit ce qui se passe. Essaie de modifier le même fichier depuis un autre endroit pendant ce temps : Fil doit s'arrêter et te laisser choisir, sans rien écraser. « Terminer » ferme la session une fois tout envoyé. Réglages › Modification choisit l'éditeur.
12. **Provoquer des erreurs** : mauvais mot de passe, mauvais port, serveur éteint, câble débranché pendant un envoi. Chaque échec doit dire pourquoi en une phrase.

## Particularités par protocole

- **FTP** n'est pas chiffré : Fil propose FTPS quand le serveur l'accepte ; sinon préfère SFTP.
- **Fichiers `.filpart`** : un envoi interrompu laisse `nom.filpart` sur le serveur jusqu'à ce que tu réessaies ou que tu effaces le transfert du plateau. Ne les supprime pas à la main pendant une reprise.
- **FTPS** : port 21 pour l'explicite, 990 pour l'implicite. Un certificat que macOS ne reconnaît pas se vérifie à l'œil puis s'épingle.
- **SFTP** : tes clés, ton agent et `~/.ssh/config` sont utilisés ; un alias de ta configuration peut servir d'adresse. Avec un mot de passe, macOS peut demander à Fil l'accès au trousseau : autorise-le. Une empreinte de serveur changée bloque la connexion, volontairement.
- **WebDAV** : HTTPS seulement. Pour Nextcloud, la racine est `/remote.php/dav/files/ton-identifiant`.
- **kDrive** : l'identifiant numérique de ton kDrive suffit comme adresse ; e-mail Infomaniak comme utilisateur ; mot de passe d'application si la double authentification est active.
- **Proton Drive** : pas encore disponible.

## Signaler un problème

Note le protocole, le type de serveur si tu le connais (OVH, Synology, Nextcloud…), la phrase affichée par Fil et ce que tu attendais. Ne joins jamais de mot de passe : Fil n'en écrit aucun dans ses journaux ni dans ses favoris.

## Pour les développeurs

`Tools/integration-tests.sh` lance des serveurs locaux (SFTP, WebDAV, FTP, FTPS) et vérifie un aller-retour complet sur chacun : envoi, listing, téléchargement octet pour octet, dossiers entiers, annulation, suppression récursive, et les erreurs attendues.
