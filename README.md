# Codex + Claude Quota Widget

Une petite app macOS de barre de menus qui affiche les quotas Codex et Claude. Par défaut, elle alterne automatiquement entre un badge ChatGPT bleu et un badge Claude orange. Chaque badge montre les quotas 5 h et 7 j.

## Prérequis

- macOS 14 ou plus récent ;
- Codex / l’app ChatGPT Desktop installé et connecté ;
- pour les quotas Claude : l’app Claude Desktop ou Claude Code 2.1.251 ou plus récent, avec un abonnement claude.ai compatible.

## Lancer

Dans Terminal, depuis ce dossier :

```sh
swift run
```

Pour créer une version optimisée :

```sh
./scripts/build-app.sh
```

L’app affiche par exemple `logo bleu 5h 84% · 7j 80%`, puis `logo orange 5h 84% · 7j 80%` dans la barre de menus. Dans le menu, choisis :

- **Afficher** : pourcentage **disponible** ou **utilisé**.
- **Services affichés** : défilement automatique, les deux côte à côte, ChatGPT seulement ou Claude seulement.
- **Quotas affichés** : 5 h et 7 j, 5 h seulement ou 7 j seulement.
- **Vitesse du défilement** : toutes les 5, 10 ou 20 secondes.

Ces choix sont mémorisés. Le défilement automatique passe d’un service à l’autre toutes les 10 secondes par défaut.

Pour Claude Desktop, le widget lit automatiquement la dernière mesure locale enregistrée par l’app. Pour Claude Code dans le terminal, le menu « Relier Claude Code (terminal) » configure sa [ligne de statut officielle](https://code.claude.com/docs/en/statusline). Si une ligne de statut personnalisée existe déjà, l'app ne la remplace pas ; intègre alors la commande `CodexQuotaWidget --claude-statusline` à ton script existant en lui transmettant son JSON d'entrée.

Les mesures Claude Desktop peuvent avoir environ 15 minutes de retard. Le widget affiche `—` lorsqu’aucune mesure récente n’est disponible : 30 minutes pour Claude Desktop, 15 minutes pour la ligne de statut Claude Code. La source et l’heure de la dernière mesure figurent dans le menu.

Fermer le Terminal ferme `swift run`, car c’est le processus de développement. Le script crée `Codex Quota.app` à la racine du projet et la lance : elle continuera à tourner sans Terminal. Tu peux ensuite déplacer cette app dans le dossier Applications ou l’ajouter au Dock.

Le build convertit automatiquement `Assets/codex-quota-icon.png` au format `.icns` et l’intègre comme icône de l’app.

## Notes de confidentialité

L’app ne stocke aucun identifiant ni aucune clé API. Elle lance `codex app-server` localement et utilise `account/rateLimits/read` ainsi que sa notification de mise à jour. Pour Claude Desktop, elle lit `~/Library/Application Support/Claude/plan-usage-history.json` sans le modifier. Pour Claude Code dans le terminal, elle enregistre uniquement la dernière mesure de quotas dans `~/Library/Application Support/CodexQuotaWidget/claude-usage.json` ; aucun accès aux identifiants Claude n'est nécessaire.
