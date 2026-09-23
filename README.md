# Codex + Claude Quota Widget

Une petite app macOS de barre de menus qui affiche les quotas Codex et Claude Code. Elle montre quatre indicateurs séparés : 5 h et 7 j pour chaque service.

## Prérequis

- macOS 14 ou plus récent ;
- Codex / l’app ChatGPT Desktop installé et connecté ;
- pour les quotas Claude : Claude Code 2.1.251 ou plus récent et un abonnement claude.ai compatible.

## Lancer

Dans Terminal, depuis ce dossier :

```sh
swift run
```

Pour créer une version optimisée :

```sh
./scripts/build-app.sh
```

L’app affiche quatre valeurs dans la barre de menus : les icônes Codex et Claude accompagnent chacune leurs quotas `5h` et `7j`. Dans le menu, choisis :

- **Afficher** : pourcentage **disponible** ou **utilisé**.

Ce choix est mémorisé.

Pour Claude Code, clique sur « Activer les quotas Claude Code », puis envoie un message dans une session Claude Code. Sa [ligne de statut officielle](https://code.claude.com/docs/en/statusline) transmet les valeurs après la première réponse. Le widget affiche `—` si la dernière mesure date de plus de 15 minutes ou si la fenêtre est expirée. Si une ligne de statut personnalisée existe déjà, l'app ne la remplace pas ; intègre alors la commande `CodexQuotaWidget --claude-statusline` à ton script existant en lui transmettant son JSON d'entrée.

Fermer le Terminal ferme `swift run`, car c’est le processus de développement. Le script crée `Codex Quota.app` à la racine du projet et la lance : elle continuera à tourner sans Terminal. Tu peux ensuite déplacer cette app dans le dossier Applications ou l’ajouter au Dock.

Le build convertit automatiquement `Assets/codex-quota-icon.png` au format `.icns` et l’intègre comme icône de l’app.

## Notes de confidentialité

L’app ne stocke aucun identifiant ni aucune clé API. Elle lance `codex app-server` localement et utilise `account/rateLimits/read` ainsi que sa notification de mise à jour. Pour Claude, elle enregistre uniquement la dernière mesure de quotas dans `~/Library/Application Support/CodexQuotaWidget/claude-usage.json` ; aucun accès aux identifiants Claude n'est nécessaire.
