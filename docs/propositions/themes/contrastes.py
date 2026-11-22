#!/usr/bin/env python3
"""Contrastes WCAG des modes graphiques proposés.

Les valeurs vivent dans index.html (bloc <script id="themes" type="application/json">) :
une seule source pour la maquette et pour ce calcul.

    python3 docs/propositions/themes/contrastes.py            # tableau lisible
    python3 docs/propositions/themes/contrastes.py --markdown # tableaux pour le README

Code de sortie 1 si une paire exigée échoue (le mode Défaut est signalé, pas bloquant :
c'est la palette livrée aujourd'hui).
"""
import json
import pathlib
import re
import sys

HERE = pathlib.Path(__file__).resolve().parent

# (premier plan, fond, seuil, rôle). Seuil 4.5 : texte (WCAG 1.4.3 AA).
# Seuil 3 : élément graphique ou d'interface (WCAG 1.4.11).
PAIRS = [
    ("ink", "ground", 4.5, "texte sur fond"),
    ("ink", "surface", 4.5, "texte sur surface"),
    ("ink", "groundSunk", 4.5, "texte, barre latérale"),
    ("inkSoft", "ground", 4.5, "texte doux sur fond"),
    ("inkSoft", "surface", 4.5, "texte doux sur surface"),
    ("inkSoft", "groundSunk", 4.5, "texte doux, barre latérale"),
    ("inkFaint", "surface", 4.5, "tailles, dates"),
    ("inkFaint", "groundSunk", 4.5, "titres de section latéraux"),
    ("accentInk", "surface", 4.5, "liens, icônes"),
    ("accentInk", "groundSunk", 4.5, "« Ajouter une connexion »"),
    ("onAccent", "accent", 4.5, "libellé du bouton principal"),
    ("accentInk", "accentWash", 4.5, "bandeau de proposition, pastille inactive"),
    ("accent", "ground", 3.0, "bouton principal sur fond"),
    ("alert", "alertWash", 4.5, "bandeau d'erreur"),
    ("alert", "surface", 4.5, "erreur sur surface"),
    ("caution", "surface", 4.5, "attention (FTP en clair)"),
    ("success", "surface", 4.5, "succès"),
    ("progress", "surface", 3.0, "barre de progression"),
    ("progress", "hairline", 3.0, "barre contre son rail"),
    ("ink", "selection", 4.5, "nom d'une ligne choisie"),
    ("accentInk", "selection", 3.0, "icône d'une ligne choisie"),
]


def load_themes():
    html = (HERE / "index.html").read_text(encoding="utf-8")
    match = re.search(r'<script id="themes" type="application/json">(.*?)</script>', html, re.S)
    if not match:
        sys.exit("Bloc de thèmes introuvable dans index.html")
    return json.loads(match.group(1))


def luminance(hex_color):
    channels = [int(hex_color.lstrip("#")[i:i + 2], 16) / 255 for i in (0, 2, 4)]
    linear = [c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4 for c in channels]
    return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]


def ratio(a, b):
    la, lb = sorted((luminance(a), luminance(b)), reverse=True)
    return (la + 0.05) / (lb + 0.05)


def rows(theme, scheme):
    values = theme[scheme]
    for fg, bg, threshold, role in PAIRS:
        value = ratio(values[fg], values[bg])
        yield fg, bg, threshold, role, value, value >= threshold


def main():
    markdown = "--markdown" in sys.argv
    themes = load_themes()
    blocking = 0
    for theme in themes:
        if markdown:
            print(f"\n#### {theme['name']} : contrastes\n")
            print("| Paire | Rôle | Seuil | Clair | Sombre |")
            print("|---|---|---|---|---|")
            light = list(rows(theme, "light"))
            dark = list(rows(theme, "dark"))
            for l, d in zip(light, dark):
                fg, bg, threshold, role = l[:4]
                cell = lambda r: f"{r[4]:.2f}".replace(".", ",") + ("" if r[5] else " ✗")
                seuil = f"{threshold:g}".replace(".", ",")
                print(f"| `{fg}` / `{bg}` | {role} | {seuil} | {cell(l)} | {cell(d)} |")
        else:
            print(f"\n== {theme['name']} ==")
        for scheme in ("light", "dark"):
            for fg, bg, threshold, role, value, ok in rows(theme, scheme):
                if not ok:
                    if theme["id"] != "defaut":
                        blocking += 1
                    if not markdown:
                        print(f"  ✗ {scheme:5} {fg:>10} / {bg:<10} {value:5.2f} < {threshold:g}  ({role})")
            if not markdown:
                values = [r[4] for r in rows(theme, scheme)]
                print(f"  {scheme:5} : minimum {min(values):.2f}")
    if not markdown:
        print(f"\n{blocking} échec(s) bloquant(s) hors Défaut.")
    sys.exit(1 if blocking else 0)


if __name__ == "__main__":
    main()
