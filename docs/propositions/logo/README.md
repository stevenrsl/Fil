# Fil : pistes d'icône

Proposition, rien n'est branché. L'icône en service reste `Support/Icon/Fil.svg`.

Toutes les pistes suivent la grille macOS : toile 1024, tuile squircle (superellipse n = 5) de 824 px posée à 100 px du bord, ombre portée douce. Couleurs prises dans [`Palette`](../../../Sources/Fil/Design/Palette.swift) : encre `#1C2636`, accent encre `#3866B3`, accent `#ABC9F0`, accent sombre `#9CCCFF`, fond `#121A26`. Une seule couleur d'accent par icône, aucune flèche, aucun nuage.

Pour chaque piste :

- `piste-x.svg` : icône macOS 1024 ;
- `piste-x-petit.svg` : version 16 et 32 px (traits épaissis, détails retirés) ;
- `piste-x-ios.svg` : carré plein bord à bord, iOS pose lui-même le masque.

`apercu/` contient les PNG 1024 rendus par `qlmanage`. `index.html` montre tout côte à côte (1024, 128, 32, 16, iOS), sur fond clair et sombre, dans un Dock et une barre latérale du Finder. Il est autonome : les SVG y sont embarqués.

## A · Fil d'Ariane

Une seule ligne d'accent traverse la tuile de gauche à droite et fait une boucle au milieu. La boucle, c'est le *l* cursif de « fil » ; la ligne qui sort des deux bords, c'est le fil qu'on ne lâche pas, d'ici à là-bas. Un seul geste, beaucoup de vide : l'icône la plus calme des quatre. En petite taille, la boucle disparaît et il reste une courbe montante épaisse.

## B · Deux rives

Un galet d'encre (ici, le Mac) et un anneau d'accent (là-bas, le serveur), reliés par un fil souple qui monte. Le transfert dit sans flèche. Lisible à 16 px. Risque : la famille visuelle « nœuds et liens » est fréquente (graphes, git, réseaux), elle dit moins « Fil » que les autres.

## C · f de nuit

Le *f* minuscule au trait, sur une tuile d'encre : l'heure de l'usage, 3 h du matin. Le fût rappelle les titres serif de Fil ; la barre du *f* est un fil plus fin qui file hors de la tuile. C'est la piste qui ressort le plus dans le Dock, et une lettre reste reconnaissable à 16 px. Risque : un monogramme sur fond sombre est un code courant, et la tuile sombre s'éloigne du fond clair de l'interface.

## D · Bobine épurée

L'icône actuelle sans le ciel ni la colline : bobine frontale et géométrique, joues à l'encre, fil enroulé et bout libre en accent. La continuité, sans rupture pour qui utilise déjà Fil. Risque : la bobine dit « couture » plus que « transfert », et reste la plus chargée à 16 px.

## Recommandation

**Piste A, Fil d'Ariane.** C'est la seule qui soit à la fois le nom (le fil, le *l* de la boucle), l'action (d'un bord à l'autre) et l'humeur de l'app (un seul trait, un seul accent, du vide). Elle applique à l'icône la règle de l'interface : un seul élément plein, rien d'autre. Elle ne ressemble à aucun client de transferts connu.

En second, **C** si l'on veut une présence plus forte dans le Dock : sa tuile d'encre pourrait aussi servir plus tard de variante sombre de A (même ligne, sur `#1C2636`) pour les icônes sombres de macOS Tahoe.

Si une piste est retenue : remplacer `Support/Icon/Fil.svg` et `Fil-iOS.svg`, régénérer `Fil-1024.png`, `Fil.icns` et l'`AppIcon` iOS comme indiqué dans `docs/DECISIONS.md` (2026-10-16), et y consigner la nouvelle décision.
