# Modes graphiques : proposition

*Proposition, non implémentée. Rien dans `Sources/` n'a changé.*

Fil a aujourd'hui une seule palette, le bleu pastel du 2026-10-09 ([`Palette`](../../../Sources/Fil/Design/Palette.swift)). Cette proposition en ajoute six autres, à la manière de Rushes : chacune a un nom, un caractère, et des valeurs complètes en clair et en sombre. Le mode actuel reste **Défaut**.

- [`index.html`](index.html) : maquette de l'écran principal (barre des connexions, navigateur, plateau avec un transfert en cours, bouton « Télécharger ») pour chaque mode, en clair, en sombre ou les deux côte à côte. Autonome, s'ouvre dans un navigateur.
- [`contrastes.py`](contrastes.py) : calcule les contrastes WCAG à partir des valeurs écrites dans `index.html` (une seule source). `python3 docs/propositions/themes/contrastes.py` sort en erreur si un mode autre que Défaut échoue ; `--markdown` régénère les tableaux ci-dessous.

## Ce qui ne change pas d'un mode à l'autre

La typographie (serif pour les titres, système pour le travail, chasse fixe pour les chiffres), les rayons, les espacements, l'icône de l'app, `darkroom` (l'aperçu photo reste noir), la règle d'un seul bouton plein. Un mode ne change **que des couleurs**, et toujours le même jeu de jetons.

## Jetons

Les quatorze jetons de `Palette` gardent leur nom et leur rôle. Trois s'ajoutent, parce qu'un mode a besoin de les régler séparément de l'accent :

| Nouveau jeton | Aujourd'hui | Pourquoi le séparer |
|---|---|---|
| `success` | `accentInk` (ligne terminée du plateau) | En Ardoise, l'accent est noir : un succès noir ne se lit pas comme un succès. |
| `progress` | `accentInk` (`ThinProgress`) | La barre doit tenir 3:1 contre son rail (`hairline`), ce que l'encre d'accent ne garantit pas partout. |
| `selection` | couleur système de `NSTableView` | La ligne choisie prend l'accent de macOS (bleu par défaut), étranger à tout mode qui n'est pas bleu. |

Dans Défaut, ces trois jetons reprennent exactement ce que les vues font aujourd'hui, sauf `selection` qui passe du bleu système à `accentWash`.

## Les sept modes en un coup d'œil

Pire cas sur toutes les paires de texte (seuil 4,5) et contraste du bouton principal sur le fond (seuil 3).

| Mode | Caractère | Texte, pire cas (clair · sombre) | Accent sur fond (clair · sombre) | Échecs AA |
|---|---|---|---|---|
| Défaut | Ciel pâle | 3,30 · 6,38 | 1,49 · 7,55 | 4 (voir plus bas) |
| Veilleuse | Ambre de nuit | 4,69 · 6,06 | 3,11 · 8,12 | aucun |
| Ardoise | Graphite | 4,81 · 6,13 | 11,99 · 14,35 | aucun |
| Lin | Papier et terre cuite | 4,65 · 6,02 | 4,62 · 6,83 | aucun |
| Mousse | Sous-bois | 4,72 · 6,59 | 4,83 · 8,63 | aucun |
| Prune | Aubergine | 5,09 · 6,23 | 6,88 · 7,93 | aucun |
| Net | Contraste élevé | 7,34 · 7,38 | 8,90 · 10,43 | aucun |

## Ce que le calcul a révélé sur Défaut

Défaut est gardé tel quel, mais le calcul trouve quatre paires sous AA dans la grille, et un vrai défaut visible hors de la grille (le premier) :

1. **Pastille de protocole inactive, en sombre : 1,36:1.** `ProtocolBadge` écrit la lettre en `onAccent` (#12213D) sur `accentWash` (#263854) : la lettre est quasi invisible dans la barre latérale sombre. Correctif proposé pour tous les modes, dans `Components.swift` : lettre en `accentInk` quand la pastille est inactive, `onAccent` seulement sur `accent`. La maquette l'applique déjà ; la paire `accentInk` / `accentWash` est vérifiée (et sert aussi au bandeau « Passer en FTPS »).
2. **Bouton principal clair : 1,49:1 contre le fond.** Le bleu poudre sur fond bleu-gris est le parti pris du pastel. Le libellé, lui, est à 7,38:1, et WCAG 1.4.11 n'exige pas le contraste du fond d'un bouton quand son texte suffit à l'identifier. Si on veut l'exigence stricte sans changer la couleur : rendre permanent le filet `accentInk` du survol (4,94:1 contre `ground`).
3. **`inkFaint` en clair : 4,06:1 sur `surface`, 3,30:1 sur `groundSunk`** (tailles, dates, titres « Favoris » et « Connexions »).
4. **`accentInk` sur `groundSunk` en clair : 4,48:1** (« Ajouter une connexion »), à un cheveu.

Un « Défaut AA » qui garde le caractère : `inkSoft` #45536A, `inkFaint` #55637A, `accentInk` #3560A8 (respectivement 6,16, 4,81 et 4,90:1 au pire). À décider séparément : c'est un changement de DA, donc une entrée dans `docs/DECISIONS.md`.

## Détail des modes

### Défaut · Ciel pâle

La palette livrée aujourd'hui : bleu poudre, encre ardoise, très peu de contraste de masse. Calme, technique, sans effet.

| Jeton | Rôle | Clair | Sombre |
|---|---|---|---|
| `ground` | fond de page | `#EBF0F7` | `#121A26` |
| `groundSunk` | barre latérale, survol d'outil | `#DBE6F2` | `#0D141F` |
| `surface` | liste, plateau, champs | `#FAFCFF` | `#1C2636` |
| `ink` | texte principal | `#1C2636` | `#EBF2FF` |
| `inkSoft` | texte secondaire | `#54637A` | `#BAC7DE` |
| `inkFaint` | tailles, dates, titres de section | `#6E7D96` | `#9EB0C9` |
| `hairline` | séparateurs, rail de progression | `#C7D4E8` | `#334561` |
| `accent` | fond du bouton principal | `#ABC9F0` | `#82ADE6` |
| `onAccent` | libellé du bouton principal | `#1A335C` | `#12213D` |
| `accentWash` | fond de proposition, pastille inactive | `#D9E8FA` | `#263854` |
| `accentInk` | liens, icônes, « Ouverte » | `#3866B2` | `#9CCCFF` |
| `alert` | erreur | `#99453B` | `#ED9485` |
| `alertWash` | fond d'erreur | `#F7E8E3` | `#3D2121` |
| `caution` | attention (FTP en clair) | `#8C6B29` | `#E6C273` |
| `success` | succès *(nouveau)* | `#3866B2` | `#9CCCFF` |
| `progress` | barre de progression *(nouveau)* | `#3866B2` | `#9CCCFF` |
| `selection` | ligne choisie *(nouveau)* | `#D9E8FA` | `#263854` |

<details><summary>Contrastes</summary>

| Paire | Rôle | Seuil | Clair | Sombre |
|---|---|---|---|---|
| `ink` / `ground` | texte sur fond | 4,5 | 13,29 | 15,55 |
| `ink` / `surface` | texte sur surface | 4,5 | 14,81 | 13,54 |
| `ink` / `groundSunk` | texte, barre latérale | 4,5 | 12,04 | 16,43 |
| `inkSoft` / `ground` | texte doux sur fond | 4,5 | 5,33 | 10,25 |
| `inkSoft` / `surface` | texte doux sur surface | 4,5 | 5,94 | 8,92 |
| `inkSoft` / `groundSunk` | texte doux, barre latérale | 4,5 | 4,83 | 10,83 |
| `inkFaint` / `surface` | tailles, dates | 4,5 | 4,06 ✗ | 6,89 |
| `inkFaint` / `groundSunk` | titres de section latéraux | 4,5 | 3,30 ✗ | 8,36 |
| `accentInk` / `surface` | liens, icônes | 4,5 | 5,51 | 9,05 |
| `accentInk` / `groundSunk` | « Ajouter une connexion » | 4,5 | 4,48 ✗ | 10,99 |
| `onAccent` / `accent` | libellé du bouton principal | 4,5 | 7,38 | 6,92 |
| `accentInk` / `accentWash` | bandeau de proposition, pastille inactive | 4,5 | 4,55 | 7,03 |
| `accent` / `ground` | bouton principal sur fond | 3 | 1,49 ✗ | 7,55 |
| `alert` / `alertWash` | bandeau d'erreur | 4,5 | 5,39 | 6,38 |
| `alert` / `surface` | erreur sur surface | 4,5 | 6,25 | 6,65 |
| `caution` / `surface` | attention (FTP en clair) | 4,5 | 4,81 | 8,93 |
| `success` / `surface` | succès | 4,5 | 5,51 | 9,05 |
| `progress` / `surface` | barre de progression | 3 | 5,51 | 9,05 |
| `progress` / `hairline` | barre contre son rail | 3 | 3,77 | 5,77 |
| `ink` / `selection` | nom d'une ligne choisie | 4,5 | 12,23 | 10,52 |
| `accentInk` / `selection` | icône d'une ligne choisie | 3 | 4,55 | 7,03 |

</details>

### Veilleuse · Ambre de nuit

Pour 3 h du matin au sens propre : peu de bleu, une lumière d'ambre basse, un noir chaud qui ne fait pas cligner. Le clair est un papier crème sous une lampe.

| Jeton | Rôle | Clair | Sombre |
|---|---|---|---|
| `ground` | fond de page | `#F4EEE3` | `#15110C` |
| `groundSunk` | barre latérale, survol d'outil | `#EAE1D1` | `#0F0C08` |
| `surface` | liste, plateau, champs | `#FBF8F2` | `#1E1912` |
| `ink` | texte principal | `#2A2118` | `#EDE2D0` |
| `inkSoft` | texte secondaire | `#5C4E3E` | `#C4B59D` |
| `inkFaint` | tailles, dates, titres de section | `#6F604C` | `#A69680` |
| `hairline` | séparateurs, rail de progression | `#DDD2BF` | `#3A3125` |
| `accent` | fond du bouton principal | `#B87A1E` | `#D9A04A` |
| `onAccent` | libellé du bouton principal | `#1F1405` | `#24170A` |
| `accentWash` | fond de proposition, pastille inactive | `#F5E4C3` | `#3A2A14` |
| `accentInk` | liens, icônes, « Ouverte » | `#87560F` | `#E8B866` |
| `alert` | erreur | `#9B3B2A` | `#E8907E` |
| `alertWash` | fond d'erreur | `#F6E0D8` | `#3A1C16` |
| `caution` | attention (FTP en clair) | `#6A621A` | `#C9C06A` |
| `success` | succès *(nouveau)* | `#4A6627` | `#A9C27F` |
| `progress` | barre de progression *(nouveau)* | `#98600F` | `#D9A04A` |
| `selection` | ligne choisie *(nouveau)* | `#F0DDB6` | `#3E2F18` |

<details><summary>Contrastes</summary>

| Paire | Rôle | Seuil | Clair | Sombre |
|---|---|---|---|---|
| `ink` / `ground` | texte sur fond | 4,5 | 13,68 | 14,67 |
| `ink` / `surface` | texte sur surface | 4,5 | 14,90 | 13,62 |
| `ink` / `groundSunk` | texte, barre latérale | 4,5 | 12,18 | 15,23 |
| `inkSoft` / `ground` | texte doux sur fond | 4,5 | 6,96 | 9,35 |
| `inkSoft` / `surface` | texte doux sur surface | 4,5 | 7,58 | 8,68 |
| `inkSoft` / `groundSunk` | texte doux, barre latérale | 4,5 | 6,19 | 9,70 |
| `inkFaint` / `surface` | tailles, dates | 4,5 | 5,74 | 6,06 |
| `inkFaint` / `groundSunk` | titres de section latéraux | 4,5 | 4,69 | 6,78 |
| `accentInk` / `surface` | liens, icônes | 4,5 | 5,88 | 9,54 |
| `accentInk` / `groundSunk` | « Ajouter une connexion » | 4,5 | 4,81 | 10,66 |
| `onAccent` / `accent` | libellé du bouton principal | 4,5 | 5,03 | 7,55 |
| `accentInk` / `accentWash` | bandeau de proposition, pastille inactive | 4,5 | 4,98 | 7,55 |
| `accent` / `ground` | bouton principal sur fond | 3 | 3,11 | 8,12 |
| `alert` / `alertWash` | bandeau d'erreur | 4,5 | 5,43 | 6,42 |
| `alert` / `surface` | erreur sur surface | 4,5 | 6,49 | 7,25 |
| `caution` / `surface` | attention (FTP en clair) | 4,5 | 5,87 | 9,34 |
| `success` / `surface` | succès | 4,5 | 6,15 | 8,90 |
| `progress` / `surface` | barre de progression | 3 | 4,93 | 7,55 |
| `progress` / `hairline` | barre contre son rail | 3 | 3,50 | 5,52 |
| `ink` / `selection` | nom d'une ligne choisie | 4,5 | 11,83 | 10,09 |
| `accentInk` / `selection` | icône d'une ligne choisie | 3 | 4,67 | 7,07 |

</details>

### Ardoise · Graphite

Presque monochrome : du gris, de l'encre, et un bouton principal noir sur blanc (blanc sur noir la nuit). Rien ne colore l'écran que les états.

| Jeton | Rôle | Clair | Sombre |
|---|---|---|---|
| `ground` | fond de page | `#EFEFEE` | `#141516` |
| `groundSunk` | barre latérale, survol d'outil | `#E4E4E2` | `#0E0F10` |
| `surface` | liste, plateau, champs | `#FAFAF9` | `#1C1D1F` |
| `ink` | texte principal | `#1B1C1E` | `#ECECEA` |
| `inkSoft` | texte secondaire | `#4A4C50` | `#B9BABD` |
| `inkFaint` | tailles, dates, titres de section | `#5F6267` | `#9A9CA0` |
| `hairline` | séparateurs, rail de progression | `#D3D4D6` | `#303235` |
| `accent` | fond du bouton principal | `#2B2D31` | `#E4E4E1` |
| `onAccent` | libellé du bouton principal | `#F5F5F4` | `#1A1B1D` |
| `accentWash` | fond de proposition, pastille inactive | `#E2E3E5` | `#2C2E31` |
| `accentInk` | liens, icônes, « Ouverte » | `#2B2D31` | `#E4E4E1` |
| `alert` | erreur | `#A3322A` | `#F08C80` |
| `alertWash` | fond d'erreur | `#F5E2DF` | `#3A1D1A` |
| `caution` | attention (FTP en clair) | `#7A5A10` | `#E3C27A` |
| `success` | succès *(nouveau)* | `#2F6B3E` | `#8CCB98` |
| `progress` | barre de progression *(nouveau)* | `#3C3F44` | `#D4D5D2` |
| `selection` | ligne choisie *(nouveau)* | `#DCDDE0` | `#34373B` |

<details><summary>Contrastes</summary>

| Paire | Rôle | Seuil | Clair | Sombre |
|---|---|---|---|---|
| `ink` / `ground` | texte sur fond | 4,5 | 14,82 | 15,46 |
| `ink` / `surface` | texte sur surface | 4,5 | 16,33 | 14,26 |
| `ink` / `groundSunk` | texte, barre latérale | 4,5 | 13,39 | 16,22 |
| `inkSoft` / `ground` | texte doux sur fond | 4,5 | 7,48 | 9,42 |
| `inkSoft` / `surface` | texte doux sur surface | 4,5 | 8,24 | 8,69 |
| `inkSoft` / `groundSunk` | texte doux, barre latérale | 4,5 | 6,76 | 9,89 |
| `inkFaint` / `surface` | tailles, dates | 4,5 | 5,86 | 6,13 |
| `inkFaint` / `groundSunk` | titres de section latéraux | 4,5 | 4,81 | 6,98 |
| `accentInk` / `surface` | liens, icônes | 4,5 | 13,21 | 13,24 |
| `accentInk` / `groundSunk` | « Ajouter une connexion » | 4,5 | 10,83 | 15,06 |
| `onAccent` / `accent` | libellé du bouton principal | 4,5 | 12,64 | 13,53 |
| `accentInk` / `accentWash` | bandeau de proposition, pastille inactive | 4,5 | 10,74 | 10,69 |
| `accent` / `ground` | bouton principal sur fond | 3 | 11,99 | 14,35 |
| `alert` / `alertWash` | bandeau d'erreur | 4,5 | 5,52 | 6,40 |
| `alert` / `surface` | erreur sur surface | 4,5 | 6,60 | 7,04 |
| `caution` / `surface` | attention (FTP en clair) | 4,5 | 6,10 | 9,85 |
| `success` / `surface` | succès | 4,5 | 6,11 | 8,93 |
| `progress` / `surface` | barre de progression | 3 | 10,12 | 11,44 |
| `progress` / `hairline` | barre contre son rail | 3 | 7,13 | 8,72 |
| `ink` / `selection` | nom d'une ligne choisie | 4,5 | 12,56 | 10,11 |
| `accentInk` / `selection` | icône d'une ligne choisie | 3 | 10,16 | 9,39 |

</details>

### Lin · Papier et terre cuite

Un carnet : papier écru, encre sépia, accent terre cuite. Chaleureux sans être sucré ; l'erreur passe au lie-de-vin pour ne pas se confondre avec l'accent.

| Jeton | Rôle | Clair | Sombre |
|---|---|---|---|
| `ground` | fond de page | `#F3EEE6` | `#1A1613` |
| `groundSunk` | barre latérale, survol d'outil | `#E9E2D6` | `#13100D` |
| `surface` | liste, plateau, champs | `#FCFAF6` | `#231E1A` |
| `ink` | texte principal | `#2B241E` | `#EFE6DC` |
| `inkSoft` | texte secondaire | `#5C5047` | `#C7B9AA` |
| `inkFaint` | tailles, dates, titres de section | `#6E6157` | `#A89A8B` |
| `hairline` | séparateurs, rail de progression | `#DCD2C4` | `#3B332C` |
| `accent` | fond du bouton principal | `#A9522E` | `#E08A62` |
| `onAccent` | libellé du bouton principal | `#FFF8F2` | `#2A140A` |
| `accentWash` | fond de proposition, pastille inactive | `#F3DDD0` | `#3E261B` |
| `accentInk` | liens, icônes, « Ouverte » | `#94421F` | `#EFA07C` |
| `alert` | erreur | `#962638` | `#F08A98` |
| `alertWash` | fond d'erreur | `#F6DFE2` | `#3C1A20` |
| `caution` | attention (FTP en clair) | `#735810` | `#E1C27A` |
| `success` | succès *(nouveau)* | `#476530` | `#A8C98C` |
| `progress` | barre de progression *(nouveau)* | `#A9522E` | `#E08A62` |
| `selection` | ligne choisie *(nouveau)* | `#F0DCCD` | `#43291D` |

<details><summary>Contrastes</summary>

| Paire | Rôle | Seuil | Clair | Sombre |
|---|---|---|---|---|
| `ink` / `ground` | texte sur fond | 4,5 | 13,24 | 14,57 |
| `ink` / `surface` | texte sur surface | 4,5 | 14,66 | 13,38 |
| `ink` / `groundSunk` | texte, barre latérale | 4,5 | 11,88 | 15,37 |
| `inkSoft` / `ground` | texte doux sur fond | 4,5 | 6,75 | 9,37 |
| `inkSoft` / `surface` | texte doux sur surface | 4,5 | 7,48 | 8,61 |
| `inkSoft` / `groundSunk` | texte doux, barre latérale | 4,5 | 6,06 | 9,88 |
| `inkFaint` / `surface` | tailles, dates | 4,5 | 5,74 | 6,02 |
| `inkFaint` / `groundSunk` | titres de section latéraux | 4,5 | 4,65 | 6,92 |
| `accentInk` / `surface` | liens, icônes | 4,5 | 6,59 | 7,85 |
| `accentInk` / `groundSunk` | « Ajouter une connexion » | 4,5 | 5,33 | 9,02 |
| `onAccent` / `accent` | libellé du bouton principal | 4,5 | 5,07 | 6,64 |
| `accentInk` / `accentWash` | bandeau de proposition, pastille inactive | 4,5 | 5,25 | 6,67 |
| `accent` / `ground` | bouton principal sur fond | 3 | 4,62 | 6,83 |
| `alert` / `alertWash` | bandeau d'erreur | 4,5 | 6,30 | 6,46 |
| `alert` / `surface` | erreur sur surface | 4,5 | 7,66 | 6,91 |
| `caution` / `surface` | attention (FTP en clair) | 4,5 | 6,43 | 9,59 |
| `success` / `surface` | succès | 4,5 | 6,35 | 8,96 |
| `progress` / `surface` | barre de progression | 3 | 5,12 | 6,27 |
| `progress` / `hairline` | barre contre son rail | 3 | 3,57 | 4,71 |
| `ink` / `selection` | nom d'une ligne choisie | 4,5 | 11,52 | 10,82 |
| `accentInk` / `selection` | icône d'une ligne choisie | 3 | 5,17 | 6,35 |

</details>

### Mousse · Sous-bois

Le retour du pastel forêt d'origine, en plus franc : sauge, vert profond, ombre végétale. Repose les yeux sur de longues sessions.

| Jeton | Rôle | Clair | Sombre |
|---|---|---|---|
| `ground` | fond de page | `#EAF0EA` | `#0E1511` |
| `groundSunk` | barre latérale, survol d'outil | `#DEE7DF` | `#0A100C` |
| `surface` | liste, plateau, champs | `#F8FBF8` | `#151F19` |
| `ink` | texte principal | `#17241C` | `#E3EEE6` |
| `inkSoft` | texte secondaire | `#435448` | `#B2C4B7` |
| `inkFaint` | tailles, dates, titres de section | `#55685B` | `#93A898` |
| `hairline` | séparateurs, rail de progression | `#CBD9CE` | `#26362C` |
| `accent` | fond du bouton principal | `#3B7350` | `#7FBF94` |
| `onAccent` | libellé du bouton principal | `#F4FBF6` | `#0D2016` |
| `accentWash` | fond de proposition, pastille inactive | `#D6E8DA` | `#1D3326` |
| `accentInk` | liens, icônes, « Ouverte » | `#2E6644` | `#92D3A7` |
| `alert` | erreur | `#A3392E` | `#EE8F84` |
| `alertWash` | fond d'erreur | `#F5E1DD` | `#3A1B18` |
| `caution` | attention (FTP en clair) | `#765A10` | `#E2C47C` |
| `success` | succès *(nouveau)* | `#2A6237` | `#92D3A7` |
| `progress` | barre de progression *(nouveau)* | `#3B7350` | `#7FBF94` |
| `selection` | ligne choisie *(nouveau)* | `#D3E6D8` | `#21392B` |

<details><summary>Contrastes</summary>

| Paire | Rôle | Seuil | Clair | Sombre |
|---|---|---|---|---|
| `ink` / `ground` | texte sur fond | 4,5 | 13,90 | 15,55 |
| `ink` / `surface` | texte sur surface | 4,5 | 15,43 | 14,20 |
| `ink` / `groundSunk` | texte, barre latérale | 4,5 | 12,72 | 16,15 |
| `inkSoft` / `ground` | texte doux sur fond | 4,5 | 6,98 | 10,12 |
| `inkSoft` / `surface` | texte doux sur surface | 4,5 | 7,75 | 9,24 |
| `inkSoft` / `groundSunk` | texte doux, barre latérale | 4,5 | 6,38 | 10,50 |
| `inkFaint` / `surface` | tailles, dates | 4,5 | 5,73 | 6,68 |
| `inkFaint` / `groundSunk` | titres de section latéraux | 4,5 | 4,72 | 7,59 |
| `accentInk` / `surface` | liens, icônes | 4,5 | 6,50 | 9,74 |
| `accentInk` / `groundSunk` | « Ajouter une connexion » | 4,5 | 5,36 | 11,08 |
| `onAccent` / `accent` | libellé du bouton principal | 4,5 | 5,32 | 7,92 |
| `accentInk` / `accentWash` | bandeau de proposition, pastille inactive | 4,5 | 5,29 | 7,79 |
| `accent` / `ground` | bouton principal sur fond | 3 | 4,83 | 8,63 |
| `alert` / `alertWash` | bandeau d'erreur | 4,5 | 5,25 | 6,59 |
| `alert` / `surface` | erreur sur surface | 4,5 | 6,33 | 7,16 |
| `caution` / `surface` | attention (FTP en clair) | 4,5 | 6,22 | 10,00 |
| `success` / `surface` | succès | 4,5 | 6,95 | 9,74 |
| `progress` / `surface` | barre de progression | 3 | 5,37 | 7,88 |
| `progress` / `hairline` | barre contre son rail | 3 | 3,82 | 5,94 |
| `ink` / `selection` | nom d'une ligne choisie | 4,5 | 12,32 | 10,47 |
| `accentInk` / `selection` | icône d'une ligne choisie | 3 | 5,19 | 7,18 |

</details>

### Prune · Aubergine

Le mode à caractère : un violet sourd, des gris lavés de prune. Pour qui veut reconnaître Fil d'un coup d'œil parmi les fenêtres.

| Jeton | Rôle | Clair | Sombre |
|---|---|---|---|
| `ground` | fond de page | `#F1EDF2` | `#17121A` |
| `groundSunk` | barre latérale, survol d'outil | `#E6E0E9` | `#110D13` |
| `surface` | liste, plateau, champs | `#FBF9FC` | `#201A24` |
| `ink` | texte principal | `#241B29` | `#EEE6F1` |
| `inkSoft` | texte secondaire | `#54465B` | `#C5B6CC` |
| `inkFaint` | tailles, dates, titres de section | `#66586E` | `#A797AF` |
| `hairline` | séparateurs, rail de progression | `#D8CEDD` | `#382E3E` |
| `accent` | fond du bouton principal | `#6B3F7E` | `#C59ADB` |
| `onAccent` | libellé du bouton principal | `#FAF5FC` | `#241330` |
| `accentWash` | fond de proposition, pastille inactive | `#E9DDEE` | `#352641` |
| `accentInk` | liens, icônes, « Ouverte » | `#6B3F7E` | `#D4AEE6` |
| `alert` | erreur | `#A3302F` | `#F08C86` |
| `alertWash` | fond d'erreur | `#F5E0DF` | `#3B1B1C` |
| `caution` | attention (FTP en clair) | `#765810` | `#E3C47A` |
| `success` | succès *(nouveau)* | `#2F6A47` | `#8DD0A6` |
| `progress` | barre de progression *(nouveau)* | `#7D4C91` | `#C59ADB` |
| `selection` | ligne choisie *(nouveau)* | `#E5D7EC` | `#3C2B48` |

<details><summary>Contrastes</summary>

| Paire | Rôle | Seuil | Clair | Sombre |
|---|---|---|---|---|
| `ink` / `ground` | texte sur fond | 4,5 | 14,35 | 15,14 |
| `ink` / `surface` | texte sur surface | 4,5 | 15,87 | 13,95 |
| `ink` / `groundSunk` | texte, barre latérale | 4,5 | 12,82 | 15,79 |
| `inkSoft` / `ground` | texte doux sur fond | 4,5 | 7,54 | 9,61 |
| `inkSoft` / `surface` | texte doux sur surface | 4,5 | 8,34 | 8,86 |
| `inkSoft` / `groundSunk` | texte doux, barre latérale | 4,5 | 6,74 | 10,03 |
| `inkFaint` / `surface` | tailles, dates | 4,5 | 6,30 | 6,23 |
| `inkFaint` / `groundSunk` | titres de section latéraux | 4,5 | 5,09 | 7,05 |
| `accentInk` / `surface` | liens, icônes | 4,5 | 7,61 | 8,91 |
| `accentInk` / `groundSunk` | « Ajouter une connexion » | 4,5 | 6,14 | 10,08 |
| `onAccent` / `accent` | libellé du bouton principal | 4,5 | 7,41 | 7,45 |
| `accentInk` / `accentWash` | bandeau de proposition, pastille inactive | 4,5 | 6,08 | 7,31 |
| `accent` / `ground` | bouton principal sur fond | 3 | 6,88 | 7,93 |
| `alert` / `alertWash` | bandeau d'erreur | 4,5 | 5,50 | 6,47 |
| `alert` / `surface` | erreur sur surface | 4,5 | 6,64 | 7,13 |
| `caution` / `surface` | attention (FTP en clair) | 4,5 | 6,32 | 10,08 |
| `success` / `surface` | succès | 4,5 | 6,13 | 9,48 |
| `progress` / `surface` | barre de progression | 3 | 6,05 | 7,31 |
| `progress` / `hairline` | barre contre son rail | 3 | 4,16 | 5,54 |
| `ink` / `selection` | nom d'une ligne choisie | 4,5 | 12,08 | 10,56 |
| `accentInk` / `selection` | icône d'une ligne choisie | 3 | 5,79 | 6,74 |

</details>

### Net · Contraste élevé

Pour les écrans fatigués, la lumière du jour, ou une vue qui baisse : noir, blanc, un bleu franc. Tout dépasse 7:1 sauf l'accent graphique.

| Jeton | Rôle | Clair | Sombre |
|---|---|---|---|
| `ground` | fond de page | `#FFFFFF` | `#000000` |
| `groundSunk` | barre latérale, survol d'outil | `#F0F0F0` | `#0D0D0D` |
| `surface` | liste, plateau, champs | `#FFFFFF` | `#0A0A0A` |
| `ink` | texte principal | `#000000` | `#FFFFFF` |
| `inkSoft` | texte secondaire | `#262626` | `#E0E0E0` |
| `inkFaint` | tailles, dates, titres de section | `#404040` | `#C2C2C2` |
| `hairline` | séparateurs, rail de progression | `#A0A0A0` | `#5A5A5A` |
| `accent` | fond du bouton principal | `#0040B0` | `#8DB8FF` |
| `onAccent` | libellé du bouton principal | `#FFFFFF` | `#000000` |
| `accentWash` | fond de proposition, pastille inactive | `#DCE6FA` | `#10264D` |
| `accentInk` | liens, icônes, « Ouverte » | `#0036A0` | `#A8C8FF` |
| `alert` | erreur | `#990000` | `#FF8A80` |
| `alertWash` | fond d'erreur | `#FDE3E3` | `#3D0A0A` |
| `caution` | attention (FTP en clair) | `#6B4A00` | `#FFD36B` |
| `success` | succès *(nouveau)* | `#00632A` | `#7FE0A0` |
| `progress` | barre de progression *(nouveau)* | `#0040B0` | `#8DB8FF` |
| `selection` | ligne choisie *(nouveau)* | `#C9D8F7` | `#1F3A6B` |

<details><summary>Contrastes</summary>

| Paire | Rôle | Seuil | Clair | Sombre |
|---|---|---|---|---|
| `ink` / `ground` | texte sur fond | 4,5 | 21,00 | 21,00 |
| `ink` / `surface` | texte sur surface | 4,5 | 21,00 | 19,80 |
| `ink` / `groundSunk` | texte, barre latérale | 4,5 | 18,43 | 19,44 |
| `inkSoft` / `ground` | texte doux sur fond | 4,5 | 15,13 | 15,91 |
| `inkSoft` / `surface` | texte doux sur surface | 4,5 | 15,13 | 15,00 |
| `inkSoft` / `groundSunk` | texte doux, barre latérale | 4,5 | 13,28 | 14,72 |
| `inkFaint` / `surface` | tailles, dates | 4,5 | 10,37 | 11,11 |
| `inkFaint` / `groundSunk` | titres de section latéraux | 4,5 | 9,10 | 10,91 |
| `accentInk` / `surface` | liens, icônes | 4,5 | 10,32 | 11,66 |
| `accentInk` / `groundSunk` | « Ajouter une connexion » | 4,5 | 9,05 | 11,45 |
| `onAccent` / `accent` | libellé du bouton principal | 4,5 | 8,90 | 10,43 |
| `accentInk` / `accentWash` | bandeau de proposition, pastille inactive | 4,5 | 8,23 | 8,80 |
| `accent` / `ground` | bouton principal sur fond | 3 | 8,90 | 10,43 |
| `alert` / `alertWash` | bandeau d'erreur | 4,5 | 7,34 | 7,38 |
| `alert` / `surface` | erreur sur surface | 4,5 | 8,92 | 8,67 |
| `caution` / `surface` | attention (FTP en clair) | 4,5 | 8,06 | 13,94 |
| `success` / `surface` | succès | 4,5 | 7,45 | 12,32 |
| `progress` / `surface` | barre de progression | 3 | 8,90 | 9,84 |
| `progress` / `hairline` | barre contre son rail | 3 | 3,40 | 3,43 |
| `ink` / `selection` | nom d'une ligne choisie | 4,5 | 14,65 | 11,20 |
| `accentInk` / `selection` | icône d'une ligne choisie | 3 | 7,20 | 6,59 |

</details>

## Esquisse d'architecture

Objectif : changer de mode sans toucher aux ~180 lectures de `Palette.x` dans les vues, sans seconde source de couleurs, et pareil sur Mac et iOS.

### Où vivent les choses

| Fichier | Contenu | Notes |
|---|---|---|
| `Sources/Fil/Design/Theme.swift` *(nouveau)* | `ThemeID` (les sept modes, `String` brut), `PaletteSet` (les dix-sept jetons en paires clair/sombre, en hex sRGB), les sept valeurs | **La seule source des couleurs.** Ne dépend que de Foundation : `ThemeID` peut être stocké par le modèle. |
| `Sources/Fil/Design/Palette.swift` | Garde ses `static let ink`, `ground`… ; chaque couleur devient dynamique sur deux axes : apparence (comme aujourd'hui) **et** mode choisi | Les vues ne changent pas. |
| `Sources/Fil/Model/ConnectionStore.swift` (`Preferences`) | `var theme: ThemeID`, clé `fil.theme` dans `UserDefaults` | Pas un secret. Valeur inconnue (mode retiré) : retombe sur `.defaut`. |
| `Sources/Fil/App/AppModel.swift` | `var theme: ThemeID { didSet { preferences.theme = theme; ThemeSelection.current = theme } }` | Même schéma que `downloadFolder`. |
| `Sources/Fil/Views/SettingsView.swift`, `iOS/Fil/Views/…` | Section « Apparence » : une grille de pastilles nommées (comme les puces de `index.html`), aucun bouton plein | Le choix s'applique tout de suite, sans « Valider ». |
| `Sources/Fil/Design/Components.swift` | `ThinProgress` lit `progress`, `ProtocolBadge` inactif écrit en `accentInk` | Petits changements de jeton, pas de forme. |
| `Sources/Fil/Views/FileTable.swift` | Un `NSTableRowView` qui dessine sa sélection en `Palette.selection` (`drawSelection(in:)`, `isEmphasized` ignoré) | Sinon la ligne choisie reste bleu système. |
| `Tests/FilTests/ThemeContrastTests.swift` *(nouveau)* | Le calcul de `contrastes.py` en Swift : chaque mode, chaque paire, chaque apparence ≥ seuil | Un mode qui casse AA ne compile pas en vert. Défaut porte ses exceptions connues, nommées. |

iOS : `Design/`, `Model/` et `App/` sont des dossiers synchronisés de `iOS/Fil.xcodeproj`, donc `Theme.swift` part sur iOS sans rien ajouter ; il ne touche ni AppKit, ni libcurl, ni `ssh`. Le fournisseur de couleur a déjà ses deux branches `NSColor` / `UIColor`.

### Comment l'écran se redessine

Les couleurs restent des `NSColor(name:dynamicProvider:)` / `UIColor(dynamicProvider:)`, résolues au dessin ; le fournisseur lit le mode courant dans un `ThemeSelection` protégé par un verrou (il peut être appelé hors du fil principal). Changer d'apparence système redessine déjà tout. Changer de mode ne change rien que SwiftUI observe : la fenêtre principale reçoit donc `.id(model.theme)` à la racine (`RootView`, `MobileRootView`, `SettingsView`). On perd l'état local des vues (texte du filtre, défilement), pas le modèle : `BrowserModel`, la file de transferts et la sélection vivent dans `AppModel`. Acceptable pour un geste qu'on fait une fois.

Plus tard, si l'on veut une bascule sans reconstruire : un `@Environment(\.palette)` lu par chaque vue. C'est la voie SwiftUI propre, mais elle touche toutes les vues ; elle peut venir après, sans changer `Theme.swift`.

### Extrait indicatif (non écrit dans `Sources/`)

```swift
// Sources/Fil/Design/Theme.swift
import Foundation
import os

/// Un mode graphique. Le nom brut est ce qui est enregistré : ne jamais le renommer.
enum ThemeID: String, CaseIterable, Codable, Sendable {
    case defaut, veilleuse, ardoise, lin, mousse, prune, net

    var label: String {
        switch self {
        case .defaut: "Défaut"
        case .veilleuse: "Veilleuse"
        case .ardoise: "Ardoise"
        case .lin: "Lin"
        case .mousse: "Mousse"
        case .prune: "Prune"
        case .net: "Net"
        }
    }

    var palette: PaletteSet {
        switch self {
        case .defaut: .defaut
        case .veilleuse: .veilleuse
        // …
        default: .defaut
        }
    }
}

/// Une couleur en clair et en sombre, en sRGB 0xRRGGBB.
struct Shade: Sendable {
    let light: UInt32
    let dark: UInt32
    init(_ light: UInt32, _ dark: UInt32) { self.light = light; self.dark = dark }
}

/// Tous les jetons d'un mode. Ajouter un jeton ici oblige à le donner à chaque mode.
struct PaletteSet: Sendable {
    let ground, groundSunk, surface: Shade
    let ink, inkSoft, inkFaint, hairline: Shade
    let accent, onAccent, accentWash, accentInk: Shade
    let alert, alertWash, caution: Shade
    let success, progress, selection: Shade
}

extension PaletteSet {
    static let veilleuse = PaletteSet(
        ground: Shade(0xF4EEE3, 0x15110C), groundSunk: Shade(0xEAE1D1, 0x0F0C08), surface: Shade(0xFBF8F2, 0x1E1912),
        ink: Shade(0x2A2118, 0xEDE2D0), inkSoft: Shade(0x5C4E3E, 0xC4B59D), inkFaint: Shade(0x6F604C, 0xA69680),
        hairline: Shade(0xDDD2BF, 0x3A3125),
        accent: Shade(0xB87A1E, 0xD9A04A), onAccent: Shade(0x1F1405, 0x24170A),
        accentWash: Shade(0xF5E4C3, 0x3A2A14), accentInk: Shade(0x87560F, 0xE8B866),
        alert: Shade(0x9B3B2A, 0xE8907E), alertWash: Shade(0xF6E0D8, 0x3A1C16), caution: Shade(0x6A621A, 0xC9C06A),
        success: Shade(0x4A6627, 0xA9C27F), progress: Shade(0x98600F, 0xD9A04A), selection: Shade(0xF0DDB6, 0x3E2F18)
    )
    // static let defaut, ardoise, lin, mousse, prune, net = …
}

/// Le mode lu au moment du dessin. Écrit par `AppModel`, lu par les fournisseurs de couleur.
enum ThemeSelection {
    private static let lock = OSAllocatedUnfairLock(initialState: ThemeID.defaut)
    static var current: ThemeID {
        get { lock.withLock { $0 } }
        set { lock.withLock { $0 = newValue } }
    }
}
```

```swift
// Sources/Fil/Design/Palette.swift : les noms ne bougent pas, seule la fabrique change.
enum Palette {
    static let ground = themed(\.ground)
    static let ink = themed(\.ink)
    static let success = themed(\.success)
    // … un par jeton ; darkroom et onDarkroom restent fixes.

    private static func themed(_ token: KeyPath<PaletteSet, Shade>) -> Color {
        #if os(macOS)
        Color(nsColor: NSColor(name: nil) { appearance in
            let shade = ThemeSelection.current.palette[keyPath: token]
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(srgb: isDark ? shade.dark : shade.light) // petite extension : 0xRRGGBB → NSColor(srgbRed:…)
        })
        #else
        Color(uiColor: UIColor { traits in
            let shade = ThemeSelection.current.palette[keyPath: token]
            return UIColor(srgb: traits.userInterfaceStyle == .dark ? shade.dark : shade.light)
        })
        #endif
    }
}
```

### Points d'attention

- **Espace colorimétrique.** `Palette` construit aujourd'hui en `calibratedRed` (RVB générique), les hex ci-dessus sont en sRGB, comme le calcul de contraste. Passer Défaut en sRGB décale très légèrement ses teintes. Soit on l'accepte (une seule fabrique, contrastes exacts), soit Défaut garde `calibratedRed` le temps d'une comparaison à l'œil.
- **`ThemeID` est une valeur pure.** Elle peut être lue et écrite par `Preferences` (Model) sans importer SwiftUI ; seule `Palette` la transforme en `Color`.
- **Accent système.** `.tint(Palette.accentInk)` sur iOS et les contrôles AppKit natifs (cases, `Picker`) suivent le mode s'ils reçoivent la teinte ; sans teinte, ils gardent l'accent de macOS. À relever écran par écran.
- **Icône.** Elle ne suit pas le mode (une icône par mode demanderait `NSApp.applicationIconImage` au lancement, hors sujet).
- **Décision.** À l'implémentation, une entrée datée dans `docs/DECISIONS.md` (nouveaux jetons, `Theme.swift`, préférence `fil.theme`, correctif de `ProtocolBadge`).

## Recommandation : trois modes d'abord

1. **Défaut**, avec le correctif de pastille et, si accepté, le « Défaut AA ». C'est le mode que tout le monde verra : il doit être irréprochable avant d'en ajouter d'autres.
2. **Veilleuse.** Le mode qui sert le mieux la promesse de Fil, « 3 h du matin » : peu de bleu, lumière d'ambre basse, rien qui éblouit. C'est aussi lui qui donne une raison d'exister au réglage.
3. **Net.** Le mode d'accessibilité : texte au-delà de 7:1 partout. Il justifie l'architecture par l'usage plutôt que par le goût, et sert de garde-fou au test de contraste (s'il passe, la mécanique tient).

Ardoise vient ensuite naturellement (le plus sobre, le plus « outil »). Lin, Mousse et Prune sont des ambiances de goût : à ajouter quand le réglage aura fait ses preuves, sans rien changer à l'architecture.
