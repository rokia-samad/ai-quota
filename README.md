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

- **Affichage** regroupe le pourcentage restant ou utilisé, les services, les fenêtres 5 h / 7 j et le défilement. Tu peux afficher les deux services côte à côte ou en alterner un seul dans la barre de menus.
- **Actualisation** : activée par défaut, toutes les 30 secondes, 1 minute ou 5 minutes. « Actualiser maintenant » lance une lecture immédiate.
- **Alertes de quota** : notifications facultatives sous 10, 20 ou 30 % disponibles, ou à un seuil personnalisé. Le seuil s’applique séparément à chaque service et fenêtre.
- **Lancer à l’ouverture de session** active ou désactive le démarrage macOS ; cette option nécessite `AI Quota.app` et non `swift run`.
- Les resets, la dernière mesure, sa source et son ancienneté apparaissent avec les quotas. Les pourcentages anciens ou indisponibles restent indiqués comme tels.

Ces choix sont mémorisés. Le défilement automatique passe d’un service à l’autre toutes les 10 secondes par défaut ; les données sont relues chaque minute par défaut.

Claude Code est la source privilégiée lorsqu’elle fournit un quota plus récent : sa [ligne de statut officiellement prise en charge](https://code.claude.com/docs/en/statusline) transmet les fenêtres 5 h et 7 j et leurs resets après une réponse éligible. « Relier Claude Code » ajoute cette commande à `~/.claude/settings.json` uniquement si aucune ligne de statut personnalisée n’existe. Les sessions existantes ne sont pas remplacées ; tu peux appeler `AIQuota --claude-statusline` depuis ton propre script.

Claude Desktop sert de source locale de secours via `~/Library/Application Support/Claude/plan-usage-history.json`. Ce fichier interne n’est pas une API publique et son format peut changer. Son historique fournit des pourcentages, sans reset. AI Quota garde les resets fournis par une mesure récente de Claude Code. Une mesure Code âgée de plus de 15 minutes ou Desktop âgée de plus de 30 minutes est marquée ancienne et ne fournit plus de pourcentage au badge. Une mesure prise avant un reset déjà passé, connu grâce à Claude Code, décrit la fenêtre précédente : elle est aussi marquée ancienne, qu’elle vienne de Claude Code ou de Claude Desktop. Une ligne de statut sans quotas efface le dernier pourcentage Claude Code mais conserve les resets déjà connus, avec leur date d’observation, pour continuer à dater les mesures plus anciennes. Les fichiers Claude sont relus au démarrage, à chaque actualisation et à l’ouverture du menu ; entre deux lectures, l’affichage utilise la mesure en mémoire. Sans mesure, le menu indique qu’une première réponse Claude Code est nécessaire ou affiche l’erreur de lecture.

Le menu indique également l’âge du dernier relevé ChatGPT et Claude. Une mesure ChatGPT devient ancienne si elle n’a pas été renouvelée depuis au moins 5 minutes (ou deux intervalles d’actualisation, si c’est plus long). Dans ce cas, le widget affiche `—` au lieu de présenter un quota périmé comme actuel. Dans la barre de menus, tout pourcentage correspondant à **moins de 10 % disponibles** passe en rouge, même si tu as choisi l’affichage en pourcentage utilisé.

Les dates de reset ChatGPT viennent de son service local. Celles de Claude ne sont affichées que si une mesure Claude Code récente fournit un reset futur valide ; l’historique Claude Desktop n’en fournit pas. Aucun identifiant ni jeton Claude n’est lu par le widget.

Fermer le Terminal ferme `swift run`, car c’est le processus de développement. Le script crée `AI Quota.app` à la racine du projet et la lance : elle continuera à tourner sans Terminal. Tu peux ensuite déplacer cette app dans le dossier Applications ou l’ajouter au Dock.

Le build convertit automatiquement `Assets/ai-quota-icon.png` au format `.icns` et l’intègre comme icône de l’app. Le nouveau logo représente un cadran de quota bleu/orange autour d’une étincelle.

## Notes de confidentialité

L’app ne stocke aucun identifiant ni aucune clé API. Elle lance le service local de ChatGPT (`codex app-server`) et utilise `account/rateLimits/read` ainsi que sa notification de mise à jour. Pour Claude Desktop, elle lit `~/Library/Application Support/Claude/plan-usage-history.json` sans le modifier. Pour Claude Code dans le terminal, elle enregistre uniquement la dernière mesure de quotas dans `~/Library/Application Support/AIQuota/claude-usage.json` ; aucun accès aux identifiants Claude n'est nécessaire.

## Diagnostic Codex et tests

Le tracker lit les quotas **Codex du compte ChatGPT**, pas les limites de tous les modèles de conversation ChatGPT. Il ne contacte aucun endpoint HTTP privé directement : il utilise le protocole local documenté [Codex App Server](https://learn.chatgpt.com/docs/app-server). Le service en amont et l’emplacement du composant embarqué peuvent toutefois évoluer.

La découverte prend en charge le composant actuel de ChatGPT Desktop (`codex-cli/CodexCLI.app/Contents/MacOS/codex`), le composant de Codex Desktop, l’ancien emplacement ChatGPT et les installations CLI Homebrew. Le bucket `codex` de `rateLimitsByLimitId` est prioritaire ; l’ancien champ `rateLimits` reste accepté lorsque la vue multi-bucket est absente. Une catégorie inconnue n’est jamais utilisée à sa place. Les notifications `account/rateLimits/updated` sont partielles : elles sont fusionnées dans la dernière lecture, une fenêtre absente garde sa valeur, et une notification visant un autre bucket est ignorée. Seules les fenêtres explicitement identifiées comme 300 ou 10080 minutes sont affichées sous les libellés 5 h / 7 j. Un reset absent ou invalide reste indisponible ; un pourcentage absent ou invalide n’est pas remplacé par zéro.

```sh
./scripts/test.sh
swift build -c release
.build/release/AIQuota --diagnose-codex
```

Les tests utilisent des fixtures synthétiques et un faux serveur local Python 3 ; ils ne nécessitent aucun compte ni accès réseau. Le diagnostic final, facultatif, lit les quotas du compte connecté sans afficher de credential. Les erreurs RPC, arrêts et délais dépassés sont signalés, les mesures en échec sont retirées de l’affichage, et l’actualisation suivante reconnecte le serveur. Les détails bruts des erreurs du serveur ne sont pas affichés.
