# AI Quota

Une petite app macOS de barre de menus qui affiche les quotas ChatGPT et Claude. Par défaut, elle alterne automatiquement entre un badge ChatGPT bleu et un badge Claude orange. Chaque badge montre les quotas 5 h et 7 j.

## Prérequis

- macOS 14 ou plus récent ;
- l’app ChatGPT Desktop installée et connectée ;
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
- **Vitesse du défilement** : toutes les 5, 10 ou 20 secondes, ou une durée personnalisée de 2 à 300 secondes. Le menu affiche le temps restant avant le prochain changement ; tu peux aussi afficher ce compte à rebours dans la barre de menus.
- **Actualisation automatique** : activée par défaut, avec une fréquence de 30 secondes, 1 minute ou 5 minutes. « Actualiser » reste disponible à tout moment.
- **Lancer à l’ouverture de session** : active ou désactive le démarrage automatique dans les réglages macOS. Cette option nécessite de lancer l’app compilée `AI Quota.app` (et non `swift run`).
- **Alertes de quota** : notifications facultatives sous 10, 20 ou 30 % disponibles, ou avec un seuil personnalisé entre 1 et 99 %. Le seuil s’applique séparément à chaque service et chaque fenêtre. macOS demande une autorisation la première fois ; l’app n’envoie pas la même alerte à chaque actualisation.
- Les dates de réinitialisation 5 h et 7 j apparaissent directement sous le quota de chaque service dans le menu, avec la date, l’heure locale et le fuseau lorsqu’elles sont disponibles.

Ces choix sont mémorisés. Le défilement automatique passe d’un service à l’autre toutes les 10 secondes par défaut ; les données sont relues chaque minute par défaut.

Pour Claude Desktop, le widget lit automatiquement la dernière mesure locale enregistrée par l’app. Pour Claude Code dans le terminal, le menu « Relier Claude Code (terminal) » configure sa [ligne de statut officielle](https://code.claude.com/docs/en/statusline) avec une actualisation toutes les 60 secondes pendant une session ouverte. Si une ligne de statut personnalisée existe déjà, l'app ne la remplace pas ; intègre alors la commande `AIQuota --claude-statusline` à ton script existant en lui transmettant son JSON d'entrée.

Les mesures Claude Desktop peuvent avoir environ 15 minutes de retard. Le widget affiche `—` lorsqu’aucune mesure récente n’est disponible : 30 minutes pour Claude Desktop, 15 minutes pour la ligne de statut Claude Code. La source et l’heure de la dernière mesure figurent dans le menu.

Le menu indique également l’âge du dernier relevé ChatGPT et Claude. Une mesure ChatGPT devient ancienne si elle n’a pas été renouvelée depuis au moins 5 minutes (ou deux intervalles d’actualisation, si c’est plus long). Dans ce cas, le widget affiche `—` au lieu de présenter un quota périmé comme actuel. Dans la barre de menus, tout pourcentage correspondant à **moins de 10 % disponibles** passe en rouge, même si tu as choisi l’affichage en pourcentage utilisé.

Les dates de reset ChatGPT sont fournies par son service local. Claude Code fournit celles de Claude via sa ligne de statut après la première réponse d’une session éligible. L’app peut combiner ces dates avec les pourcentages plus récents de Claude Desktop. Le fichier local de Claude Desktop ne contient pas ces dates : si aucune session Claude Code n’a fourni de données récentes, le menu indique « non fourni par Claude Desktop » plutôt que d’estimer une date. Aucun identifiant ni jeton Claude n’est lu par le widget.

Fermer le Terminal ferme `swift run`, car c’est le processus de développement. Le script crée `AI Quota.app` à la racine du projet et la lance : elle continuera à tourner sans Terminal. Tu peux ensuite déplacer cette app dans le dossier Applications ou l’ajouter au Dock.

Le build convertit automatiquement `Assets/ai-quota-icon.png` au format `.icns` et l’intègre comme icône de l’app. Le nouveau logo représente un cadran de quota bleu/orange autour d’une étincelle.

## Notes de confidentialité

L’app ne stocke aucun identifiant ni aucune clé API. Elle lance le service local de ChatGPT (`codex app-server`) et utilise `account/rateLimits/read` ainsi que sa notification de mise à jour. Pour Claude Desktop, elle lit `~/Library/Application Support/Claude/plan-usage-history.json` sans le modifier. Pour Claude Code dans le terminal, elle enregistre uniquement la dernière mesure de quotas dans `~/Library/Application Support/AIQuota/claude-usage.json` ; aucun accès aux identifiants Claude n'est nécessaire.
