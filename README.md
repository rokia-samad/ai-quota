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

## Windows — application native dans la zone de notification

La version Windows est séparée dans [`windows/`](windows/ARCHITECTURE.md). Elle utilise **C# / .NET 10 LTS / WinForms NotifyIcon**, sans Electron, WebView, backend ni fenêtre principale. Le code et les instructions macOS ci-dessus restent inchangés. .NET 10 est la version LTS retenue pour cette nouvelle application ([installation officielle](https://learn.microsoft.com/en-us/dotnet/core/install/windows)).

### Prérequis et compilation

- Windows 10/11 **x64** pris en charge par .NET 10 ;
- pour compiler : **SDK .NET 10**, par exemple `winget install Microsoft.DotNet.SDK.10` ;
- pour Codex : le CLI Windows installé et connecté à un compte ChatGPT compatible (`codex login`) ;
- facultatif : Claude Code **2.1.251+** avec des quotas `rate_limits` disponibles pour le compte. Claude n’est pas nécessaire à Codex.

Dans PowerShell, à la racine du repository :

```powershell
dotnet test
dotnet build -c Release
dotnet publish -c Release
.\artifacts\windows\win-x64\AIQuota.exe
```

L’exécutable exact est **`artifacts\windows\win-x64\AIQuota.exe`**. Il est publié **self-contained x64**, en fichier unique : aucun runtime .NET séparé n’est nécessaire sur la machine cible. Le runtime Desktop inclus explique la taille du fichier (environ 111 Mio). La compilation/restauration nécessite Internet pour les composants .NET et xUnit ; les tests eux-mêmes utilisent uniquement des fixtures et un faux serveur local, sans compte réel. Un smoke test supplémentaire de l’exécutable publié est disponible : `powershell -NoProfile -File windows/scripts/Smoke.ps1` ; ses données sont isolées dans un dossier temporaire.

Pour installer, copie `AIQuota.exe` dans un dossier utilisateur stable, par exemple `%LOCALAPPDATA%\Programs\AIQuota`, puis lance-le. L’application continue de tourner après fermeture de PowerShell. Windows peut placer l’icône dans le volet des icônes masquées : utilise la flèche de la zone de notification pour la retrouver ou l’épingler. **Quitter** termine l’application. Pour désinstaller, désactive d’abord le lancement automatique et retire, si tu l’as configurée, la commande status line Claude ; quitte ensuite l’application et supprime son dossier.

### Codex CLI

Vérifie d’abord dans PowerShell :

```powershell
Get-Command codex
where.exe codex
codex login
```

AI Quota recherche `codex.exe`, `codex.cmd` ou `codex.bat` dans le `PATH` hérité. Si nécessaire, il interroge `Get-Command codex` dans Windows PowerShell sans charger de profil, puis vérifie les emplacements utilisateur npm et `.local\bin`. Les shims npm `.cmd` sont pris en charge, y compris avec des espaces dans le chemin. Les fonctions et alias définis uniquement dans un profil PowerShell ne constituent pas un exécutable lançable par l’app : expose le CLI dans `PATH`. Après une installation ou une modification du `PATH`, relance AI Quota.

L’app lance **`codex app-server`**, effectue le handshake et lit **`account/rateLimits/read`**, puis écoute les notifications documentées ([protocole officiel](https://learn.chatgpt.com/docs/app-server)). Elle affiche uniquement le bucket **`codex`** : ce sont les quotas Codex du compte ChatGPT, pas ceux de tous les modèles de conversation ChatGPT. Aucun endpoint HTTP privé, fichier de credential ou token n’est lu par AI Quota. Le CLI gère lui-même sa connexion existante.

### Menu et préférences

Clic gauche ou droit sur l’icône :

- **ChatGPT / Codex** puis **Claude** : quotas 5 h / 7 j, resets, date de chaque mesure, source et état frais / ancien / indisponible ;
- **Actualiser maintenant** ;
- **Affichage** : Disponible ou Utilisé ; **Quotas** : les deux fenêtres, seulement 5 h ou seulement 7 j ;
- **Actualisation automatique** : désactivée, 30 secondes, 1 minute (défaut), 5 minutes ;
- **Alertes** : désactivées (défaut), sous 10, 20 ou 30 % disponibles ;
- **Lancer avec Windows**, **Relier Claude Code…**, **Quitter**.

Le tooltip résume ChatGPT, et Claude sur une seconde ligne si la limite native de 127 caractères le permet. Le texte ne s’ajoute pas à la barre des tâches. Les pourcentages anciens sont masqués. Chaque fenêtre Codex conserve sa propre date lors des notifications partielles ; elle devient ancienne après 5 minutes ou deux intervalles d’actualisation si c’est plus long, ou après son reset connu. Les erreurs retirent les valeurs Codex ; la prochaine actualisation reconnecte le serveur. Claude reste indépendant.

Les alertes utilisent les notifications ballon Windows, éventuellement masquées par les réglages Windows ou le mode concentration. Une alerte n’est pas répétée à chaque refresh : la dernière fenêtre/reset signalée est mémorisée par service. Sans reset connu, une nouvelle alerte devient possible après remontée au-dessus du seuil. Aucun seuil personnalisé n’est proposé dans cette première version.

**Lancer avec Windows** ajoute ou retire uniquement la valeur utilisateur `AIQuota` dans `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`. Aucun droit administrateur n’est nécessaire, et rien n’est activé au premier lancement. Active cette option après avoir placé l’exécutable dans son dossier définitif. Si tu le déplaces, désactive puis réactive l’option depuis le nouvel emplacement.

### Relier Claude Code sous Windows

La [status line officielle prend en charge Windows](https://code.claude.com/docs/en/statusline#windows-configuration) et transmet les fenêtres indépendantes `rate_limits.five_hour` / `seven_day` après une réponse éligible. Dans le menu, **Relier Claude Code…** ajoute la commande uniquement si aucune `statusLine` n’existe dans **`%USERPROFILE%\.claude\settings.json`** (ou dans `CLAUDE_CONFIG_DIR` si défini). Les autres réglages sont conservés. Aucune modification n’est faite avant cette action explicite. Laisse l’exécutable à un emplacement stable avant de le relier.

La commande invoque explicitement Windows PowerShell, ce qui fonctionne aussi lorsque Claude Code utilise Git Bash. Elle lit son JSON sur stdin et appelle `AIQuota.exe --claude-statusline`. L’encodage de la commande protège les espaces et caractères spéciaux du chemin. Une status line existante n’est jamais remplacée : tu peux intégrer manuellement un appel à l’exécutable dans ton script existant, en lui transmettant le même JSON avant d’afficher ton propre résultat. Exemple PowerShell, à adapter au chemin installé :

```powershell
$json = [Console]::In.ReadToEnd()
$json | & "$env:LOCALAPPDATA\Programs\AIQuota\AIQuota.exe" --claude-statusline | Out-Null
# Utiliser ensuite $json pour ta propre ligne de statut.
```

Seules les données de quota validées sont conservées : pourcentages 0–100, dates de mesure et resets. Aucun credential ni identifiant de session n’est conservé. Une entrée sans quotas efface les anciens pourcentages, tout en gardant les resets et leur date d’observation pour reconnaître une ancienne fenêtre. Claude est ancien après 15 minutes ou après un reset connu ; seuls les resets futurs récemment observés sont affichés. Une première réponse Claude Code éligible est nécessaire pour obtenir des quotas. **Claude Desktop Windows n’est pas pris en charge** : aucun fichier local équivalent fiable n’a été retenu, et aucun fallback n’est inventé.

### Diagnostics et données locales

Un WinExe ne bloque pas toujours PowerShell sans pipeline. Pour attendre la fin et obtenir le résultat :

```powershell
.\artifacts\windows\win-x64\AIQuota.exe --diagnose-codex | Out-Host
.\artifacts\windows\win-x64\AIQuota.exe --diagnose-claude | Out-Host
```

Codex indique le chemin découvert, le succès du handshake, la lecture du bucket et les valeurs/reset disponibles. Claude indique la source, les chemins, les mesures et leur fraîcheur. Codes de sortie : `0` lecture réussie, `1` erreur, `2` absence de mesure exploitable ou option inconnue. Les diagnostics n’affichent ni credentials ni erreurs brutes du serveur. Pour obtenir le code dans un script qui doit attendre explicitement, utilise `Start-Process -Wait -PassThru`.

Les données sont sous **`%LOCALAPPDATA%\AIQuota`** : `preferences.json` (affichage, fréquence, alertes et identités déjà signalées) et `claude-usage.json` (dernière mesure Claude uniquement). Les quotas Codex restent en mémoire. `AIQUOTA_DATA_DIR` permet de remplacer ce dossier, notamment pour des tests isolés. L’option de lancement Windows est lue directement dans la clé utilisateur Run. Aucune donnée n’est envoyée par AI Quota à un backend ou service tiers.

L’audit, l’architecture et les limites de validation sont détaillés dans [`windows/ARCHITECTURE.md`](windows/ARCHITECTURE.md). La CI Windows teste et publie séparément ; la CI macOS existante est conservée.
