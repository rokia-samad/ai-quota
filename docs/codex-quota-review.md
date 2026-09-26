# Revue ciblée du tracker Codex

## Diagnostic observé

Le checkout distant examiné est `33414ad`. Les sources locales initiales étaient absentes ; la correction est réalisée dans un clone séparé, sans toucher à l’application installée.

L’ancien résolveur ne connaît que `/Applications/ChatGPT.app/Contents/Resources/codex`, `/usr/local/bin/codex` et `/opt/homebrew/bin/codex`. Aucun de ces chemins n’existe sur le Mac examiné. Le composant actuel est `/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex`. Le tracker échoue donc avant le handshake et avant le parsing. Le fonctionnement antérieur reposait sur l’ancien emplacement ; la date exacte du changement de packaging n’a pas été déterminée.

Un handshake réel avec le composant actuel et une lecture `account/rateLimits/read` ont réussi. La réponse contient notamment `rateLimits` et `rateLimitsByLimitId`, avec le bucket `codex`, les fenêtres 300/10080 minutes, `usedPercent` et `resetsAt`. Le format historique reste fourni : aucune rupture de schéma ni erreur d’authentification n’a été observée dans ce diagnostic.

## Chemin des données

Composant local Codex → processus `app-server` → handshake JSONL → lecture ou notification → parser QuotaCore → mesure en mémoire et horodatage → rendu AppKit. Aucun backend HTTP propre ni cache Codex sur disque. Les préférences d’affichage sont stockées dans UserDefaults ; les caches Claude restent indépendants.

QuotaCore extrait uniquement le client et les types auparavant dans main.swift afin de tester leur frontière sans lancer AppKit. Les resets deviennent optionnels. La vue multi-bucket est prioritaire lorsqu’elle est présente ; aucun bucket inconnu ne sert de fallback. Les fenêtres sont associées aux libellés par durée explicite ; une durée absente ne justifie pas d’inventer une fenêtre.

## Problèmes corrigés lors de la revue

- Découverte du nouvel emplacement du composant ChatGPT, avec maintien des anciens chemins.
- Continuations sans délai ni résolution à la sortie du serveur : délai de 20 secondes, invalidation de la connexion et reconnexion à l’actualisation suivante.
- Initialisation concurrente : une tâche partagée bloque les lectures jusqu’à la fin du handshake.
- Ordre des fragments stdout : AsyncStream préserve l’ordre avant décodage JSONL.
- Pipe stderr non consommé : sortie dirigée vers le périphérique nul, sans exposer des messages potentiellement sensibles.
- Erreurs RPC génériques : conservation du code, sans afficher le message brut du serveur.
- Notifications invalides silencieusement ignorées : invalidation explicite de la mesure.
- Erreur UI écrasée par le rendu, ou ancien titre conservé après réponse partielle : état d’erreur persistant et affichage des fenêtres indépendamment.
- Fermeture depuis le menu : arrêt explicite du serveur enfant.

## Validation et limites

16 tests indépendants du compte : fixtures actuelles et historiques synthétiques, 0/100 %, champs optionnels, reset invalide, fenêtres inconnues/inversées, payload partiel/invalide, découverte, échec de lancement, arrêt, timeout/retry, erreur RPC, fragments JSONL, lectures concurrentes et notification. Build release et compilation Swift 6 passent. Lint strict limité aux fichiers QuotaCore/tests/manifest ; aucun lint global n’existait. Une CI macOS est ajoutée.

Le diagnostic du binaire corrigé récupère les quotas réels. Aucun test visuel manuel du menu, expiration réelle de session ou simulation HTTP n’a été effectué : HTTP et auth appartiennent au serveur Codex, les tests couvrent leurs erreurs à la frontière RPC. Aucun identifiant n’est lu par AI Quota. Aucune configuration Claude ni donnée utilisateur n’a été modifiée.

## Recommandations hors périmètre

Les pourcentages Claude ne bénéficient pas encore de la même validation numérique que Codex, et les erreurs de lecture/écriture du bridge Claude sont souvent ignorées. Ajouter des fixtures et un état d’erreur explicite pour Claude mérite un changement distinct afin de préserver ce provider.

Le menu de détails et les alertes utilisent encore la fraîcheur du relevé, alors que le badge vérifie aussi la date de reset. Harmoniser ces règles pour les deux providers éviterait une alerte issue d’une fenêtre récemment expirée.

Le script historique `build-app.sh` lance automatiquement l’app ; il n’a pas été exécuté pour cette PR. Une option de packaging sans lancement serait utile à l’avenir.

Le protocole local est documenté, mais ce n’est pas une API publique générale de quotas ChatGPT : il reflète les limites Codex et dépend du composant embarqué ainsi que de services OpenAI susceptibles d’évoluer. Voir https://learn.chatgpt.com/docs/app-server.
