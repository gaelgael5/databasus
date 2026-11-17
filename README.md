# Databasus — stack Docker Compose pour homelab

Déploiement autonome et versionnable de [Databasus](https://github.com/databasus/databasus)
(sauvegarde PostgreSQL / MySQL / MariaDB / MongoDB, Apache 2.0), prévu pour être
déclaré comme stack dans Komodo.

Contenu du dépôt :

| Fichier | Rôle |
| --- | --- |
| `docker-compose.yml` | le service, sans aucun secret |
| `dev-deploy.sh` | script d'amorçage : `.env`, réseau externe, validation, `up -d` |
| `.env.example` | toutes les variables, valeurs factices, à copier en `.env` |
| `.gitignore` | ignore `.env` |
| `README.md` | ce document |

---

## 1. Ce qui a été vérifié dans la doc officielle

Tout ce tableau vient du dépôt amont (`README.md`, `install-databasus.sh`,
`Dockerfile`) et des pages du site officiel présentes dans ce dépôt
(`website/app/(en)/installation`, `.../advanced-config`, `.../storages`).

| Point | Valeur vérifiée |
| --- | --- |
| Image | `databasus/databasus` (miroir : `ghcr.io/databasus/databasus`) |
| Tag recommandé | la doc utilise `latest` ; **aucun canal « stable » distinct n'est documenté**. Ici on épingle `v3.70.1` (dernier tag publié sur Docker Hub au 17/11/2026) |
| Port | `4005` (`EXPOSE 4005` dans l'image) |
| Volume à persister | `/databasus-data` — base interne, configuration, clé de chiffrement, journaux |
| Healthcheck | `databasus healthcheck` ; déjà présent dans l'image (`HEALTHCHECK`, `start-period=60s`) |
| Variables obligatoires | **aucune**. La doc « Advanced config » précise : « a standard single-container install needs no configuration at all. Every variable on this page is optional » |
| Base PostgreSQL compagnon | **non**. L'image embarque PostgreSQL 17 et démarre son propre cluster dans `/databasus-data/pgdata` |
| Ressources minimales | 1 cœur CPU, 500 Mo de RAM, 5 Go de disque + la place des sauvegardes |
| Durée de démarrage | jusqu'à ~2 minutes |
| Destinations de sauvegarde | configurées **dans l'interface web**, pas dans le compose (cf. §5) |

Liste complète des variables documentées (toutes optionnelles) : OAuth Google et
GitHub, SMTP + `DATABASUS_URL`, Cloudflare Turnstile,
`IS_DISABLE_ANONYMOUS_TELEMETRY`, journalisation (`LOG_LEVEL`,
`LOG_FILE_IS_ENABLED`, `OPEN_TELEMETRY_URL`, `OPEN_TELEMETRY_HEADERS`),
`ANALYTICS_SCRIPT`, `PUID` / `PGID`. Elles sont toutes reprises, commentées,
dans `.env.example` — **aucune variable inventée**.

---

## 2. Prérequis

- Docker Engine 20.10+ et Docker Compose v2+.
- Le réseau Docker externe qui servira à joindre les bases des autres stacks :

```bash
docker network create databases
```

Si vos stacks PostgreSQL partagent déjà un réseau, ne le recréez pas : mettez
son nom dans `DATABASUS_DB_NETWORK` (`docker network ls` pour le retrouver).
Le réseau doit exister **avant** le premier `docker compose up`, sinon le
démarrage échoue avec `network databases declared as external, but could not be found`.

---

## 3. Démarrage

```bash
git clone <ce-dépôt> databasus && cd databasus
./dev-deploy.sh
```

`dev-deploy.sh` est idempotent et fait tout l'amorçage : vérification de Docker,
création de `.env` depuis `.env.example` s'il manque, création du réseau externe
s'il manque, `docker compose config -q`, `pull`, `up -d`, puis attente de l'état
« healthy » avant d'afficher l'URL. Options : `--no-pull`, `--no-wait`,
`--help`. Relancez-le après chaque `git pull` ou changement de `DATABASUS_TAG`.

Équivalent à la main :

```bash
cp .env.example .env          # adapter si besoin : port, tag, nom du réseau
docker network create databases
docker compose up -d
docker compose ps             # attendre l'état « healthy » (jusqu'à ~2 min)
```

Puis ouvrir `http://<ip-de-la-machine>:4005`.

Le fichier `.env` doit exister : le compose le déclare en `env_file`, et
`docker compose up` échoue s'il est absent.

Dans Komodo : déclarer la stack sur ce dépôt, chemin du compose
`docker-compose.yml`, et coller le contenu de `.env.example` adapté dans le
champ *Environment* de la stack. Komodo écrit ce contenu dans un `.env` à côté
du compose, ce que `env_file: .env` attend ; si votre version utilise un autre
nom de fichier (réglage *env file path*), alignez la valeur de `env_file` dans
`docker-compose.yml`. Le réseau externe doit être créé sur le serveur cible au
préalable.

### Première connexion à l'interface

1. `http://<ip>:4005` → écran d'inscription. **Le premier compte créé administre
   l'instance.**
2. Créez-le et connectez-vous. Variante sans navigateur :
   `docker exec -it databasus ./main --create-user --email="ops@exemple.net" --password="…" --role=admin`.
3. Les fonctions d'invitation, de réinitialisation de mot de passe et de code à
   six chiffres par email n'existent que si vous configurez le SMTP
   (`SMTP_HOST`, cf. `.env.example`). Sans SMTP, l'écran de connexion masque le
   lien « mot de passe oublié » ; le reset passe alors par la ligne de commande
   (§7).
4. Déclarez ensuite, dans cet ordre : un *Storage* (§5), puis une *Database*
   (§4), son planning et sa politique de rétention, enfin les notifications.

---

## 4. Joindre des bases PostgreSQL d'autres stacks Docker

Le compose rattache le conteneur à deux réseaux : son réseau de projet (sortie
internet vers B2/R2) et le réseau externe `databases`.

**Cas 1 — la base est dans une autre stack de la même machine (recommandé).**
Rattachez le service PostgreSQL de cette stack au même réseau externe :

```yaml
# docker-compose.yml de la stack à sauvegarder
services:
  postgres:
    networks: [default, databases]
networks:
  databases:
    name: databases
    external: true
```

Dans Databasus, l'hôte de la base est alors le **nom du service ou du conteneur
PostgreSQL** (`postgres`, `immich_postgres`, …) et le port `5432`, sans aucune
publication de port sur l'hôte. Vérification rapide :

```bash
docker compose exec databasus getent hosts postgres
```

**Cas 2 — la base tourne sur l'hôte (hors Docker) ou vous ne voulez pas toucher
aux autres stacks.** La doc amont ne propose alors que le mode réseau *host* :
remplacez, dans `docker-compose.yml`, les blocs `ports:` et `networks:` par
`network_mode: host` ; l'interface est alors sur `http://<ip>:4005` sans
publication, et les bases se joignent via `127.0.0.1`. Ce mode ne fonctionne
nativement que sous Linux.

**Dans tous les cas** : créez dans chaque base un utilisateur de sauvegarde
dédié. Databasus se sert par défaut d'un utilisateur en lecture seule et ne
stocke rien qui puisse modifier vos données.

---

## 5. Préparer Backblaze B2 et Cloudflare R2

Les destinations ne sont **pas** dans le compose : elles se créent dans
l'interface (*Storages* → nouvelle destination de type *S3*). Vérifié : la doc
amont ne documente aucune variable d'environnement pour les stockages.

Le formulaire S3 attend : **Bucket**, **Region**, **Access key**, **Secret
key**, **Endpoint**, **Prefix** (chemin dans le bucket, figé après création),
plus les options *virtual-hosted style*, *skip TLS verify* et *storage class*.

### Backblaze B2 — copie de référence avec Object Lock

À préparer côté fournisseur avant la première connexion :

1. Un bucket **privé**, créé avec Object Lock activé (le verrou ne s'active pas
   après coup sur un bucket existant) et une durée de rétention par défaut.
2. Une **Application Key** créée à la main (la master key ne fonctionne pas sur
   l'API S3), limitée à ce bucket, avec au minimum `listBuckets`/`listFiles`,
   `readFiles`, `writeFiles`, `deleteFiles` — et `listAllBucketNames` si la clé
   est restreinte à un bucket, pour la compatibilité des SDK S3.
3. L'**endpoint S3** affiché sur la page du bucket, de la forme
   `https://s3.<région>.backblazeb2.com`.
4. La **région**, visible dans cet endpoint (`us-west-004`, `eu-central-003`, …).

### Cloudflare R2 — copie secondaire

Procédure documentée par Databasus (`https://databasus.com/storages/cloudflare-r2`) :

1. Créer le bucket, et noter son nom.
2. **Region** : la valeur à saisir est `auto`.
3. *R2 → API → Manage API Tokens* : créer un token avec la permission
   *Object Read & Write*. Vous obtenez un **Access Key ID** (identifiant du
   token) et un **Secret Access Key**.
4. Relever l'**Account ID** affiché sur les pages R2.
5. **Endpoint** : `https://<ACCOUNT_ID>.r2.cloudflarestorage.com`.

### Deux destinations pour une même base : à savoir avant de commencer

La doc amont ne dit rien du cas « une base, deux destinations ». Le code amont,
lui, est net : une configuration de sauvegarde porte **une seule** destination
(`BackupConfig.StorageID`, un identifiant unique, dans
`backend/internal/modules/backups/internal/config/backup_config.go`), et cette
configuration est rattachée à une base (`DatabaseID`). Il n'existe donc pas de
case « envoyer aussi vers R2 ».

Deux contournements, à choisir selon le besoin :

- **Déclarer la base deux fois** dans Databasus (par exemple
  `immich (B2)` et `immich (R2)`), chaque entrée avec sa destination, son
  planning et sa rétention. Simple, mais la base est lue deux fois : décalez les
  horaires.
- **Répliquer B2 → R2 en dehors de Databasus** (`rclone sync`, planifié sur
  l'hôte). La base n'est lue qu'une fois et la copie secondaire est un miroir
  exact de la copie de référence ; en revanche la réplication n'est plus
  surveillée par Databasus.

Pour un bucket de référence sous Object Lock, la seconde option évite en outre
de faire travailler la rétention de Databasus sur le bucket verrouillé (cf. §6.4).

---

## 6. Points non documentés en amont

Listés ici plutôt que devinés.

1. **`TZ`** n'apparaît dans aucune page de la doc Databasus. La variable est
   posée (contrainte homelab, convention Docker) mais l'effet réel sur l'heure
   des plannings n'est pas garanti par la doc, et l'image est basée sur
   `debian:bookworm-slim`, qui n'embarque pas forcément la base de fuseaux.
   À vérifier après le premier démarrage : `docker compose exec databasus date`.
   Si l'heure reste en UTC, décalez les plannings dans l'interface.
2. **Rattachement à un réseau Docker externe** : non documenté. La doc ne traite
   que le cas `network_mode: host` (bases sur l'hôte). Le réseau partagé est un
   usage Docker standard, mais il n'est pas couvert par la doc amont.
3. **Volume nommé** : la doc utilise systématiquement un bind mount
   `./databasus-data`. Le volume nommé répond à la contrainte « pas de chemin
   absolu » et survit à `down`/`up`. Conséquence connue : avec un bind mount,
   Databasus déduit son UID/GID du propriétaire du dossier ; avec un volume
   nommé il retombe sur `999`. Si une erreur de permission apparaît sur
   `/databasus-data`, posez `PUID`/`PGID` (cf. `.env.example`).
4. **Object Lock** : Databasus ne documente nulle part son comportement face à un
   bucket verrouillé. Or ses politiques de rétention suppriment des objets, et
   d'après la doc Backblaze toute suppression d'une version verrouillée échoue
   avant la fin de la rétention. Conséquence probable : des erreurs de ménage
   côté B2. Faites la rétention Object Lock **plus courte ou égale** à la
   rétention Databasus, et surveillez les notifications après le premier cycle
   de purge.
5. **Backblaze B2** n'a pas de page dédiée côté Databasus (seule R2 en a une) ;
   B2 passe par le type *S3* avec endpoint personnalisé. Les éléments du §5 sur
   B2 viennent de la documentation Backblaze, pas de celle de Databasus.
6. **`start_period: 120s`** et **`stop_grace_period: 60s`** sont des choix de ce
   dépôt (la doc annonce ~2 min de démarrage ; l'arrêt propre du PostgreSQL
   embarqué mérite plus que les 10 s par défaut). L'image amont utilise
   `start-period=60s`.
7. **Vérification de restauration** : la fonction existe mais exige un *agent de
   vérification* (binaire à lancer sur une machine disposant de Docker, créé
   depuis *Settings → Verification agents*). Elle n'est donc pas couverte par
   cette stack, qui ne monte volontairement pas le socket Docker.

---

## 7. Exploitation

```bash
# Journaux
docker compose logs -f databasus

# État de santé (le healthcheck du conteneur)
docker inspect --format '{{.State.Health.Status}}' databasus

# Endpoint de supervision (200 = sain, 503 + raison sinon)
curl -i http://localhost:4005/api/v1/system/health

# Mise à jour : changer DATABASUS_TAG dans .env, puis
docker compose pull && docker compose up -d

# Mot de passe oublié (sans SMTP)
docker exec -it databasus ./main --list-admins
docker exec -it databasus ./main --new-password="…" --email="ops@exemple.net"
```

L'endpoint `/api/v1/system/health` est destiné à la supervision, pas à une
sonde de redémarrage : il renvoie 503 pour des états dégradés mais fonctionnels
(disque à plus de 95 %, par exemple).

**Sauvegarder Databasus lui-même.** Le volume `databasus-data` contient la clé
de chiffrement de vos sauvegardes : sans elle, les archives chiffrées déposées
sur B2 et R2 sont inutilisables. Copiez-la (ou sauvegardez le volume) et gardez
cette copie ailleurs que sur la machine qui héberge la stack :

```bash
docker run --rm -v databasus_databasus-data:/data:ro -v "$PWD":/out \
  debian:bookworm-slim tar czf /out/databasus-data.tgz -C /data .
```

Le nom du volume est préfixé par le nom du projet Compose (`databasus_` ici,
celui de la stack dans Komodo sinon) : vérifiez avec `docker volume ls`.

---

## Licences

Databasus est publié sous Apache 2.0 par le projet amont. Ce dépôt ne contient
que des fichiers de déploiement.
