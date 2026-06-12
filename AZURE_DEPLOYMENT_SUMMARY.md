# Azure Deployment Summary

## STATUS: RADI (2026-06-12)

Cijeli stack radi sa stvarnim Moodleom (ne vise nginx fallback):

- jump host -> interni load balancer -> app VM -> Moodle vraca **HTTP 200**
- oba LB-a (`10.20.1.10`, `10.21.1.10`) -> HTTP 200
- sve 4 app VM-ke -> HTTP 200, **0 restarts** (nema vise crash-loopa)
- MariaDB `healthy`, Moodle log: `** Moodle setup finished! **`

Moodle admin (test): `admin` / `Moodle_Admin_123`.

## Trenutno stanje

Terraform deployment je prosao i Azure infrastruktura je kreirana:

- resource groupovi za core, Luku i Ivu
- lead/jump VNet i jump VM
- developer VNetovi za Luku i Ivu
- 2 private app VM-ke po developeru
- internal load balancer po developeru
- NSG pravila za SSH/HTTP
- VNet peering izmedu lead mreze i developer mreza
- storage accountovi, blob containeri, file shareovi i data diskovi
- NAT Gateway za outbound internet iz private app subnetova

## Sto radi

Mrezni dio radi.

S jump hosta se moze pristupiti internim load balancerima:

```bash
curl http://10.20.1.10
curl http://10.21.1.10
```

Test je vratio `HTTP/1.1 200 OK` za oba load balancera.

To znaci da radi put:

```text
jump VM -> internal load balancer -> private app VM
```

Na app VM-kama trenutno radi fallback `nginx` container na portu 80, samo da se dokaze da load balancer i mreza rade.

## Sto je bilo pokvareno (povijest)

Full Moodle aplikacija prije nije uspjesno dignuta. Lanac problema:

- originalni `cloud-init` je prvo pao jer app VM-ke nisu imale outbound internet
- nakon dodavanja NAT Gatewaya internet je proradio
- zatim je originalna skripta pala jer paket `docker-compose-plugin` nije dostupan na toj Ubuntu slici
- taj dio je zamijenjen s `docker-compose-v2`
- originalni Bitnami image tagovi `bitnami/moodle:4.5` i `bitnami/mariadb:11.4` se vise nisu mogli povuci
- prebaceno je na `bitnamilegacy/*`, ali Moodle container se i dalje restartao tijekom setupa

**Glavni skriveni kvar:** ti rucni popravci su razbili YAML indentaciju u
`cloud-init-app.yaml.tpl`. Linije `apt-get install ...` te oba `image:` retka bile
su uvucene s manje razmaka od baze `content: |` bloka (6 razmaka). U YAML-u to
prekida literal blok scalar, pa cloud-init nije mogao ispravno isparsirati
datoteku ni pouzdano pokrenuti `install.sh`.

## Sto je popravljeno

`cloud-init-app.yaml.tpl` je prepisan i sada:

- ima ispravnu, konzistentnu YAML indentaciju (provjereno parserom; i vanjski
  cloud-config i ugnijezdeni `docker-compose.yml` su valjan YAML)
- instalira Docker preko sluzbenog Docker apt repozitorija
  (`docker-ce` + `docker-compose-plugin`), s fallbackom na `docker.io` +
  `docker-compose-v2`/`docker-compose`
- pokrece compose i preko `docker compose` (plugin) i preko `docker-compose`
- pinna stabilne tagove `bitnamilegacy/mariadb:11.4` i `bitnamilegacy/moodle:4.5`
  (umjesto `:latest`, koji u legacy arhivi cesto ne postoji)
- rjesava glavni uzrok restart-loopa: rucni bind-mount direktoriji `/data/mariadb`
  i `/data/moodle` se prije pokretanja `chown`-aju na `1001:1001` (Bitnami
  runtime user), inace non-root container ne moze pisati i pada u petlji
- koristi konzistentne, eksplicitne DB lozinke + MariaDB healthcheck, a Moodle
  ceka `condition: service_healthy` prije starta
- dodaje 2 GB swap da prvi (memorijski tezak) Moodle install ne dobije OOM kill

Default Moodle admin (za test): korisnik `admin`, lozinka `Moodle_Admin_123`.

### Jednokratni gotcha: ustajali MariaDB data disk

Nakon `apply`-a Moodle se i dalje restartao s greskom `Could not connect to the
database`, iako je MariaDB bila `healthy`. Uzrok: managed data diskovi su ostali
od ranijih slomljenih pokusaja, pa je `/data/mariadb` vec bio inicijaliziran sa
*praznim* lozinkama. MariaDB kod postojeceg data dira preskace inicijalizaciju i
**ignorira** nove `MARIADB_PASSWORD`/`MARIADB_ROOT_PASSWORD`, pa je Moodle s novom
lozinkom dobivao `Access denied`. (Healthcheck je svejedno prolazio jer
`mysqladmin ping` javlja "alive" i kod access-denied.)

Rijeseno tako da su ustajali podaci obrisani i stack ponovno dignut na svakoj
app VM-ki:

```bash
sudo docker compose -f /opt/moodle/docker-compose.yml down
sudo rm -rf /data/mariadb /data/moodle
sudo mkdir -p /data/mariadb /data/moodle
sudo chown -R 1001:1001 /data/mariadb /data/moodle
sudo docker compose -f /opt/moodle/docker-compose.yml up -d
```

Napomena: kod cistog `terraform destroy` + `terraform apply` ovaj problem ne
postoji jer se data diskovi kreiraju prazni, pa se MariaDB inicijalizira svjeze
s tocnim lozinkama. Problem se javlja samo kad se VM-ke recreate-aju nad vec
postojecim (starim) data diskovima.

## Kako provjeriti nakon `terraform apply`

```powershell
terraform output jump_public_ip
ssh azureadmin@<JUMP_PUBLIC_IP>
```

S jump hosta (Moodle prvi put zna trebati nekoliko minuta da se inicijalizira):

```bash
curl -I http://10.20.1.10
curl -I http://10.21.1.10
```

Direktno na app VM-ki, ako treba debug:

```bash
docker compose -f /opt/moodle/docker-compose.yml ps
docker compose -f /opt/moodle/docker-compose.yml logs --tail=50 moodle
cloud-init status --long
sudo cat /var/log/cloud-init-output.log
```

## Zakljucak

Mrezni dio (privatne VM-ke, jump host, interni load balanceri, outbound preko
NAT-a) je vec radio. Sada je popravljen i aplikacijski dio: `cloud-init` je
ponovno valjan YAML, a Moodle/MariaDB stack je postavljen stabilno (ispravni
image tagovi, dozvole na volumenima, healthcheck i swap). Sljedeci `terraform
apply` (ili recreate app VM-ova) trebao bi dignuti stvarni Moodle umjesto
nginx fallbacka.

