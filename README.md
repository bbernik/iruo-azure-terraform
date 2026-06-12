# IRUO – Azure Terraform (TechSprint Moodle okolina)

Terraform automatizacija za Azure dio IRUO projekta. Iz jedne CSV datoteke
(developeri + DevOps lead) kreira izoliranu testnu okolinu za Moodle aplikaciju.

## Što kreira

- **Jump host** – jedina VM s javnim IP-om, ulaz za SSH
- **Izolirana mreža po developeru** (VNet) – developeri se međusobno ne vide
- **2 privatne Moodle VM-ke po developeru** (2 vCPU / 4 GB, OS disk + data disk)
- **Interni load balancer** po developeru
- **Storage account** – Blob (objekti) + Files (backup), montirano na VM-ke
- **NSG/ASG** pravila i **NAT gateway** (izlaz na internet)
- **RBAC** role za upravljanje VM-ovima (developer = samo svoje, lead = sve)
- Svi resursi tagirani: `project: techsprint`, `environment: testing`

Moodle se diže preko `cloud-init`-a (Docker Compose: Moodle + MariaDB).

## Pokretanje

```powershell
copy terraform.tfvars.example terraform.tfvars
# uredi terraform.tfvars: allowed_ssh_cidr, ssh_public_key, users_csv_path

az login
terraform init
terraform plan
terraform apply
```

## Testiranje

```powershell
terraform output jump_public_ip          # javni IP jump hosta
terraform output developer_internal_load_balancers   # interni LB IP-ovi
```

SSH na jump host pa provjera internog load balancera:

```bash
ssh azureadmin@<JUMP_IP>
curl -I http://10.20.1.10        # treba vratiti HTTP 200
```

Moodle u browseru (SSH tunel kroz jump host):

```powershell
ssh -i <privatni_kljuc> -L 8080:10.20.1.10:80 azureadmin@<JUMP_IP>
# pa otvori http://localhost:8080   (login: admin / Moodle_Admin_123)
```

## CSV format (točka-zarez)

```csv
ime;prezime;rola;principal_object_id
ana;anic;devops_lead;<entra-object-id>
luka;lukic;developer;<entra-object-id>
iva;ivic;developer;<entra-object-id>
```

`principal_object_id` je opcionalan – ako je prazan, preskače se RBAC za tog korisnika.

## Čišćenje

```powershell
terraform destroy
```

## Napomena

Tajne (`terraform.tfvars`, `terraform.tfstate`, SSH ključevi) su u `.gitignore`
i **ne** idu na GitHub. Detaljan opis deploya i troubleshooting su u
[AZURE_DEPLOYMENT_SUMMARY.md](AZURE_DEPLOYMENT_SUMMARY.md).
