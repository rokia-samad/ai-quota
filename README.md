# Codex Quota Widget

Application macOS de barre de menus pour visualiser les quotas Codex ChatGPT.

## Fonctionnalités

- Pourcentage disponible ou utilisé
- Fenêtre de 5 h ou hebdomadaire
- Rafraîchissement automatique

## Lancer

```sh
swift run
```

Pour créer l’app autonome sans dépendre du Terminal :

```sh
zsh scripts/build-app.sh
```

Le build convertit automatiquement `Assets/codex-quota-icon.png` au format `.icns` et l’intègre comme icône de l’app.

Prérequis : Codex / ChatGPT Desktop installé et connecté.
