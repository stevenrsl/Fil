# Notes de distribution

Rien n'est encore distribué. Ces notes fixent la marche à suivre le moment venu.

## Construire

1. Construire hors d'un dossier synchronisé (iCloud Drive, Dropbox) : les attributs étendus ajoutés par la synchronisation cassent la signature.

   ```sh
   FIL_APP_DIR=~/Builds Tools/bundle.sh release
   ```

2. Remplacer la signature ad hoc par une identité Developer ID, avec le runtime renforcé :

   ```sh
   codesign --force --options runtime --timestamp --sign "Developer ID Application: …" ~/Builds/Fil.app
   ```

3. Notariser, agrafer, puis recopier sans attributs étendus ni ressources :

   ```sh
   ditto --noextattr --norsrc ~/Builds/Fil.app /Applications/Fil.app
   ```

## Avant la première distribution

- Choisir l'identifiant de bundle définitif (provisoire : `com.fil.app` dans `Support/Info.plist`) et le service Keychain associé (`com.fil.connections`). Changer l'un ou l'autre fait perdre l'accès aux favoris ou aux mots de passe enregistrés : prévoir une migration.
- Icône d'application.
- Le runtime renforcé n'empêche ni de lancer `/usr/bin/ssh` ni de charger la libcurl système. La sandbox, elle, les empêche : pas de distribution App Store sans revoir SFTP.
- Aucune télémétrie, aucune vérification de mise à jour réseau sans décision explicite.

## Dépendances système

- `libcurl` (FTP, FTPS) : bibliothèque de macOS, liée dynamiquement, non embarquée.
- `/usr/bin/ssh` (SFTP) : OpenSSH de macOS, appelé comme processus.
- Aucune bibliothèque tierce dans l'application.
