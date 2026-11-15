# TeslaMirror

TeslaMirror recopie l'écran d'un iPhone dans le navigateur d'une Tesla, en passant par le partage de connexion de l'iPhone.
L'iPhone héberge un petit serveur web. La Tesla, connectée au Wi‑Fi de l'iPhone, ouvre **http://172.20.10.1:8080**.

> ⚠️ **Usage à l'arrêt uniquement.** Il n'y a aucun contrôle tactile depuis la voiture, car iOS ne permet pas d'injecter des touches.

## Architecture

| Cible | Rôle |
|---|---|
| `TeslaMirror` (app SwiftUI) | Contient le bouton `RPSystemBroadcastPickerView`. Affiche l'URL et le QR code, et choisit l'interface réseau (partage de connexion ou Wi‑Fi). Interroge `127.0.0.1:8080/status` pour afficher l'état. |
| `TeslaMirrorBroadcast` (Broadcast Upload Extension) | Reçoit les `CMSampleBuffer` de ReplayKit, les encode et **héberge le serveur** (`NWListener` sur le port 8080, toutes interfaces). Le serveur vit dans l'extension parce que l'app principale est suspendue en arrière-plan. |

Le dossier `Core/` est compilé dans l'extension. Il n'utilise ni ReplayKit ni UIKit, ce qui permet de le tester sur macOS (voir plus bas).

| Fichier | Contenu |
|---|---|
| `MirrorServer.swift` | Serveur HTTP/1.1 et WebSocket écrits à la main au-dessus de Network.framework |
| `JPEGEncoder.swift` | V1 : réduction en 720p et JPEG qualité 0,5 via Core Image |
| `H264Encoder.swift` | V2 : H.264 VideoToolbox matériel. Mode *low latency* avec repli automatique, profil Baseline, pas de B-frames, keyframe ≤ 1 s, 3 Mbit/s. VideoToolbox réduit lui-même l'image en 720p. |
| `FMP4Muxer.swift` | Muxeur MP4 fragmenté (init segment + un fragment `moof`/`mdat` par image), timeline contiguë |
| `MirrorPipeline.swift` | Cadence et distribue les images : H.264 à 30 i/s, MJPEG à 12 i/s quand un client regarde (1 i/s sinon, pour garder une image en cache) |
| `WebPages.swift` | Pages HTML/JS servies au navigateur |

### Routes HTTP

| Route | Contenu |
|---|---|
| `/` | Accueil : bouton « Recopier l'écran » et raccourcis vers Netflix, YouTube, Disney+… Ces services sont protégés par DRM (noirs en recopie, iOS l'impose), ils sont donc ouverts et lus **directement par le navigateur de la voiture**. |
| `/mirror` | **V2** : lecteur H.264. WebSocket `/ws` → fMP4 → Media Source Extensions. Bascule automatiquement sur `/mjpeg` si MSE ou le codec n'est pas disponible, ou si rien n'est décodé au bout de 10 s. |
| `/mjpeg` | **V1** : `<img src="/stream">` plein écran |
| `/stream` | flux `multipart/x-mixed-replace` (JPEG) |
| `/ws` | WebSocket. Le serveur envoie d'abord un message texte `{"type":"init","codec":"avc1.…"}`, puis l'init segment en binaire, puis un fragment fMP4 par image. |
| `/health` | répond `ok` |
| `/status` | JSON : rotation, nombre de clients, codec, résolution |

WebCodecs n'est pas utilisé : il exige un contexte sécurisé (HTTPS ou localhost), ce que `http://172.20.10.1` n'est pas. MSE n'a pas cette contrainte.

### Contraintes mémoire (~50 Mo pour l'extension)

- Aucun `CMSampleBuffer` ni `CVPixelBuffer` n'est conservé. Le downscale est fait par VideoToolbox (H.264) ou par Core Image (JPEG) pendant l'appel.
- Seules des **données encodées** sont gardées en cache : le dernier JPEG, et le dernier GOP H.264 plafonné à 3 Mo. Ce cache sert à afficher tout de suite quelque chose à un client qui se connecte alors que l'écran est statique, puisque ReplayKit n'envoie alors plus d'images.
- Les files d'envoi sont bornées :
  - MJPEG : une image est sautée si l'envoi précédent n'est pas terminé.
  - WebSocket : au-delà de 1,5 Mo en attente, tout est jeté jusqu'à la prochaine keyframe, qui est alors forcée.
- 6 clients au maximum.

### Rotation

ReplayKit livre toujours des images en portrait, avec une étiquette d'orientation (`RPVideoSampleOrientationKey`). La rotation est appliquée **dans le navigateur** (CSS), ce qui évite de réencoder et de recréer la session H.264.

La correspondance orientation → angle reprend celle de l'intégration ReplayKit de Jitsi/WebRTC, mais **elle n'a pas encore été validée sur un appareil réel**. Si l'image apparaît à l'envers, le bouton ↻ de la page ajoute 90° de rotation manuelle. Ce réglage est mémorisé par le navigateur.

### App Group

Aucun App Group n'est nécessaire. L'app lit l'état directement sur le serveur de l'extension, via `http://127.0.0.1:8080/status`.

## Compiler et installer

Prérequis : Xcode 15 ou plus récent, un iPhone sous iOS 17+ et un compte développeur Apple (un compte gratuit suffit pour tester).

1. Ouvrez `TeslaMirror.xcodeproj`.
2. Pour **chaque** cible (`TeslaMirror` et `TeslaMirrorBroadcast`), ouvrez *Signing & Capabilities* et choisissez votre *Team*. Vous pouvez aussi renseigner `DEVELOPMENT_TEAM` dans `project.yml`.
3. Si le bundle ID `com.teslamirror.TeslaMirror` est déjà pris, changez `BUNDLE_ID_PREFIX` dans `project.yml`, puis lancez `xcodegen generate`. Vous pouvez aussi changer les deux bundle IDs à la main. L'extension **doit** garder le bundle ID de l'app suivi de `.Broadcast`.
4. Lancez le schéma `TeslaMirror` sur l'iPhone.

> Le simulateur compile le projet mais **ne peut pas diffuser** : ReplayKit n'y fonctionne pas. Les tests se font sur un iPhone réel.

## Tester

### Étape 1 : un autre appareil sur le même réseau Wi‑Fi

1. Connectez l'iPhone et un Mac (ou un iPad) au **même Wi‑Fi**.
2. Dans TeslaMirror, sélectionnez « Wi‑Fi — 192.168.x.y » dans le menu Réseau.
3. Touchez **Démarrer la diffusion**, choisissez *TeslaMirror*, puis *Démarrer la diffusion*. Le compte à rebours de 3 s s'affiche, puis la pastille rouge apparaît.
4. Si iOS demande l'accès au réseau local, acceptez.
5. Dans Safari sur le Mac, ouvrez `http://192.168.x.y:8080` puis « Recopier l'écran de l'iPhone ». L'écran de l'iPhone doit s'afficher en H.264. L'indicateur en haut à gauche, qui s'affiche quand on touche la page, montre le codec.
6. Ouvrez `http://192.168.x.y:8080/mjpeg` pour vérifier la V1.
7. Points à vérifier :
   - **latence** : faites défiler une page sur l'iPhone. Attendez moins de 0,5 s en H.264, et plus en MJPEG.
   - **rotation** : passez l'iPhone en paysage dans une app qui le permet (Photos, vidéo).
   - **écran statique** : rechargez la page alors que rien ne bouge sur l'iPhone. L'image doit apparaître tout de suite.
   - **état** : le bandeau de l'app indique le nombre de clients.

Safari macOS a été testé avec le harnais : il lit le flux H.264. Sur iPhone ou iPad, la page utilise `ManagedMediaSource` (iOS 17.1+), mais ce cas n'a pas encore été testé. En cas d'échec, elle bascule seule sur MJPEG.

### Étape 2 : la Tesla

1. Sur l'iPhone, activez *Réglages → Partage de connexion → Autoriser d'autres utilisateurs*. Activer *Maximiser la compatibilité* peut aider.
2. Sur la Tesla, connectez-vous au Wi‑Fi de l'iPhone (*Contrôles → Wi‑Fi*).
3. Lancez la diffusion depuis TeslaMirror. L'URL par défaut est `http://172.20.10.1:8080`.
4. Ouvrez le navigateur de la Tesla et tapez `http://172.20.10.1:8080`. Le bouton *Plein écran* et le bouton ↻ apparaissent quand on touche l'écran.

### Dépannage

| Symptôme | Piste |
|---|---|
| L'extension n'apparaît pas dans la liste de diffusion | Le bundle ID de l'extension doit être celui de l'app suivi de `.Broadcast`. Réinstallez l'app. |
| La diffusion s'arrête aussitôt avec « Le serveur n'a pas pu démarrer » | Le port 8080 est déjà occupé. Arrêtez puis relancez la diffusion. |
| Page inaccessible depuis le Mac | Autorisez TeslaMirror dans *Réglages → Confidentialité → Réseau local*. Vérifiez aussi que les deux appareils sont sur le même réseau. |
| Page inaccessible depuis la Tesla | Des utilisateurs signalent que le navigateur Tesla refuse certaines IP privées, et que l'isolation des clients du partage de connexion peut bloquer le trafic. Ce n'est pas confirmé officiellement. Essayez *Maximiser la compatibilité*, coupez puis réactivez le partage de connexion, et vérifiez que la Tesla a bien une IP en `172.20.10.x`. |
| H.264 noir ou bloqué | Utilisez `/mjpeg`, qui marche sur tout navigateur. La page `/` y bascule seule si elle ne décode rien en 10 s. |
| L'image est tournée dans le mauvais sens | Utilisez le bouton ↻ de la page. Merci de signaler la correction nécessaire pour qu'on ajuste la correspondance par défaut dans `SampleHandler.swift`. |
| La diffusion est coupée par iOS | La limite mémoire de l'extension est dépassée. Réduisez le débit dans `MirrorPipeline.swift` et regardez les logs `[TeslaMirror]` dans Console.app. |

## Tester le cœur sans iPhone (macOS)

```sh
Tools/run-harness.sh 8099 60 /tmp/dump.mp4
# puis ouvrir http://127.0.0.1:8099/ et http://127.0.0.1:8099/mjpeg dans Chrome ou Safari
```

Le harnais compile `Core/` pour macOS et injecte des images synthétiques en 1179×2556. La cadence est irrégulière, avec une pause de 4 s toutes les 15 s pour simuler un écran statique, et une rotation de 90° qui alterne toutes les 20 s. Le fichier `dump.mp4` (init + fragments) se lit avec QuickTime ou AVFoundation.

## Régénérer le projet Xcode

```sh
brew install xcodegen
xcodegen generate
```

## Netflix et autres services protégés

iOS met en noir toute vidéo protégée par DRM (Netflix, Disney+, Prime Video, Apple TV+…) dans une recopie d'écran, y compris pour son propre enregistreur d'écran. Seuls les sous-titres restent visibles, et le son reste sur le téléphone. Aucune app de recopie ne peut contourner cela.

Les apps CarPlay comme CarTV n'ont pas ce problème, car elles ne recopient pas l'écran : elles lisent la vidéo elles-mêmes et la dessinent sur l'écran CarPlay, qu'iOS gère comme un second écran. La Tesla n'est pas un écran de l'iPhone. L'équivalent consiste donc à faire lire la vidéo **par le navigateur de la voiture**, et c'est le rôle des raccourcis de la page d'accueil. Pour Netflix, l'app *Theater* intégrée à la Tesla reste l'option la plus fiable.
