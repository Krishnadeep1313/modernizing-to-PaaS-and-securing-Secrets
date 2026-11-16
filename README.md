# ☁️ Lab 03: Modernizing to PaaS & Securing Secrets

![Azure](https://img.shields.io/badge/azure-%230072C6.svg?style=for-the-badge&logo=microsoftazure&logoColor=white)
![Azure SQL](https://img.shields.io/badge/Azure_SQL-0078D4?style=for-the-badge&logo=microsoftsqlserver&logoColor=white)
![Key Vault](https://img.shields.io/badge/Key_Vault-C19C00?style=for-the-badge&logo=microsoftazure&logoColor=white)

**Author:** Krishnadeep Chudasama · **Estimated Time:** 60 minutes · **Difficulty:** Intermediate

🎥 **WATCH ME COMPLETE THIS LAB HERE:**

*Video walkthrough coming soon.*

<!-- TODO: replace the line above with the Loom link once the video is recorded -->

## 📋 Table of Contents
- [Objective](#-objective)
- [Architecture Diagram](#-architecture-diagram)
- [Prerequisites](#-prerequisites)
- [Lab Variables](#-lab-variables)
- [Step-by-Step Instructions](#-step-by-step-instructions)
  - [Phase 1: Decommission the Old Database VM](#phase-1-decommission-the-old-database-vm)
  - [Phase 2: Deploy Azure SQL Database (PaaS)](#phase-2-deploy-azure-sql-database-paas)
  - [Phase 3: Deploy Azure Key Vault](#phase-3-deploy-azure-key-vault)
  - [Phase 4: Store the SQL Password as a Secret](#phase-4-store-the-sql-password-as-a-secret)
  - [Phase 5: Enable Managed Identity and Grant Key Vault Access](#phase-5-enable-managed-identity-and-grant-key-vault-access)
  - [Phase 6: Validate with Azure Monitor](#phase-6-validate-with-azure-monitor)
- [Security Notes](#-security-notes)
- [Troubleshooting](#-troubleshooting)
- [Key Concepts](#-key-concepts)
- [Lab Completion Checklist](#-lab-completion-checklist)
- [Clean Up Resources](#-clean-up-resources)

---

## 🎯 Objective
Refactor the Lab 02 infrastructure: replace a self-managed database VM with a fully managed Azure SQL Database, store the database password in Azure Key Vault, and give the web server a **Managed Identity** so it can read that password without any credential in code or on the server.

By the end you will have:
- Decommissioned `vm-db-01` (VM, OS disk and NIC) from Lab 02
- Deployed an **Azure SQL Database** (PaaS)
- Deployed an **Azure Key Vault** holding the SQL admin password as a secret
- Enabled a **system-assigned Managed Identity** on `vm-web-01` with read-only access to that secret
- Confirmed the database is live with **Azure Monitor**

> **Refactor** means improving how something is built without changing what it does. Swapping a database VM (you patch, back up and keep it available) for a managed service (Azure does) is a common "lift and modernize" pattern.

## 🏗️ Architecture Diagram

![Lab 03 architecture: vm-web-01 with a managed identity reads a secret from Key Vault and connects to Azure SQL Database; vm-db-01 is deleted](images/lab03-architecture.png)

**How to read it:** (1) `vm-web-01` proves who it is with its Managed Identity and reads `SqlAdminPassword` from Key Vault. (2) It connects to `sqldb-app` using that password. The old `vm-db-01` is gone.

## ✅ Prerequisites
- [x] Active Azure Subscription
- [x] Lab 02 complete: `vm-web-01` running in `rg-lab02-krish`

## ⚙️ Lab Variables (Naming Convention)
* **Resource Group:** `rg-lab03-krish`
* **SQL Server:** `sql-server-krish` (globally unique, lowercase)
* **SQL Database:** `sqldb-app`
* **Key Vault:** `kv-lab03-krish` (globally unique)
* **Secret:** `SqlAdminPassword`
* **Region:** East US

> SQL Servers and Key Vaults get public DNS names (for example `sql-server-krish.database.windows.net`), so no two Azure customers can share a name.

---

## 🚀 Step-by-Step Instructions

### Phase 1: Decommission the Old Database VM
In a real migration you would move the data first, verify, then retire the old server. This lab simulates only the final decommission step.

1. Go to **Resource groups** → `rg-lab02-krish`.
2. Select the three resources tied to `vm-db-01`: the VM, its OS disk (`vm-db-01_OsDisk_...`) and its NIC (`vm-db-01-nic` or similar). Check each one's Overview tab if unsure.
3. Click **Delete**, type `delete`, confirm.

> ⚠️ Do **not** delete the resource group or `vm-web-01`. A stopped VM still bills for its disk and IP, which is why we delete rather than stop.

✅ **Verify:** `vm-db-01`, its disk and its NIC are gone; `vm-web-01` is still there.

### Phase 2: Deploy Azure SQL Database (PaaS)
> A **SQL Server** in Azure is a logical container (admin login, firewall rules, region). A **SQL Database** is the actual database inside it. Create the server first, then the database.

1. Search **SQL databases**, open the **+ Create** dropdown and choose **SQL database** (not the Free offer).
2. **Remove the Free offer banner** ("Advanced configuration" / "Remove offer") before anything else. While it is applied, the DTU tier does not appear.
3. **Resource group:** Create new → `rg-lab03-krish`.
4. **Database name:** clear the auto-filled name and enter `sqldb-app`. (Databases cannot be renamed later.)
5. **Server:** Create new:
   - **Server name:** `sql-server-krish`
   - **Location:** (US) East US
   - **Authentication:** Use SQL authentication
   - **Server admin login:** `sqladmin`
   - **Password:** strong password, saved somewhere safe (you need it in Phase 4)
6. **SQL elastic pool:** No. **Workload environment:** Development (it defaults to Production, which defaults to a very expensive tier).
7. **Compute + storage → Configure database:** choose **DTU-based → Basic** (about $4.99/month), then **Apply**. If the DTU option is missing, the free offer is still applied.
8. **Backup storage redundancy:** Locally-redundant (LRS).
9. **Networking:** Connectivity method **Public endpoint**; **Allow Azure services and resources to access this server** = Yes; **Add current client IP address** = Yes; TLS 1.2.
10. **Security:** Microsoft Defender for SQL = Not now (costs about $15/server/month).
11. **Additional settings:** leave defaults (blank database, default collation).
12. **Review + create** → **Create** (2–3 minutes).

✅ **Verify:** `sqldb-app` Overview shows the server name and status **Online**.

> **My run:** the database landed on the **Free - General Purpose - Serverless** tier, so Phase 6 uses *CPU percentage* instead of *DTU percentage*. See Troubleshooting.

### Phase 3: Deploy Azure Key Vault
> Key Vault is a secure, audited store for secrets, keys and certificates. Applications fetch secrets at runtime instead of keeping them in config files or source control.

1. Search **Key vaults** → **+ Create**.
2. **Resource group:** `rg-lab03-krish`. **Name:** `kv-lab03-krish`. **Region:** East US. **Pricing tier:** Standard.
3. **Recovery options:** leave soft-delete (90 days) and **leave purge protection disabled**, or you cannot permanently delete the vault during cleanup.
4. **Access configuration:** keep **Azure role-based access control** (RBAC). Leave the three Resource access checkboxes unchecked.
5. **Networking:** defaults (public access, all networks). Expect the "not recommended for private applications" warning; fine for a lab.
6. **Review + create** → **Create**.

✅ **Verify:** the Overview shows the Vault URI (`https://kv-lab03-krish.vault.azure.net/`).

**Grant yourself access first.** With RBAC nobody has data access by default, including the creator. Opening **Secrets** shows *"You are unauthorized to view these contents."* That is expected.

1. Key Vault → **Access control (IAM)** → **+ Add → Add role assignment**.
2. Role: **Key Vault Administrator**. Members: yourself (**User, group, or service principal**).
3. **Review + assign** (twice). Wait 1–2 minutes.

> I get **Key Vault Administrator** (full management, needed to set the vault up). The VM later gets only **Key Vault Secrets User** (read secret values). That split is least privilege in practice.

### Phase 4: Store the SQL Password as a Secret
1. Key Vault → **Objects → Secrets** → **+ Generate/Import**.
2. **Upload options:** Manual. **Name:** `SqlAdminPassword`. **Secret value:** the SQL admin password from Phase 2. Leave the rest at defaults.
3. **Create.**

✅ **Verify:** `SqlAdminPassword` is listed as **Enabled**. Open its current version: you see metadata, never the value unless you explicitly choose to show it.

> Secret names allow only letters, numbers and hyphens.

### Phase 5: Enable Managed Identity and Grant Key Vault Access
> A **Managed Identity** is an identity Azure attaches to a resource and manages for you. The VM can prove "I am `vm-web-01`" with no password stored anywhere. **System-assigned** identities are tied to one resource and deleted with it.

**Part A: Enable it on the VM**
1. `rg-lab02-krish` → `vm-web-01` → **Identity**.
2. **System assigned** tab → Status **On** → **Save** → **Yes**.

✅ **Verify:** an **Object (principal) ID** appears.

**Part B: Grant the VM read access to the secret**
1. `kv-lab03-krish` → **Access control (IAM)** → **+ Add → Add role assignment**.
2. Role: **Key Vault Secrets User** → Next.
3. **Assign access to:** Managed identity → **+ Select members** → **Virtual machine** → `vm-web-01` → Select → Next.
4. **Review + assign** (twice).

✅ **Verify:** the **Role assignments** tab lists `vm-web-01`, role *Key Vault Secrets User*, type *VirtualMachines*.

> If `vm-web-01` does not appear, confirm Part A was saved and wait about 60 seconds.

### Phase 6: Validate with Azure Monitor
> Observability means understanding a system's state from its outputs (metrics, logs, traces). Monitoring is how you know something is healthy before users tell you it is not.

1. **SQL databases** → open **`sqldb-app`** (the header should say *SQL database*, not *SQL server*).
2. Check **Pricing tier** in Essentials.
3. Left menu → **Monitoring → Metrics**.
4. Chart settings, **Metric:** `CPU percentage` (my database is on the Free Serverless tier; on the Basic tier use `DTU percentage`), **Aggregation:** `Max`.

✅ **Verify:** a chart renders with a visible line and no errors. Near-zero activity is fine: the line proves the database is alive and monitored.

![sqldb-app Metrics page showing Max CPU percentage](images/lab03-cpu-metrics.png)

<!-- TODO: add images/lab03-cpu-metrics.png (blur the email in the top-right before uploading) -->

### Bonus: Prove the Managed Identity works
The role assignment only configures access. This proves it. SSH into `vm-web-01`, then:

```bash
# 1. Ask the Azure Instance Metadata Service for a token for Key Vault (only works from inside the VM)
TOKEN=$(curl -s -H "Metadata:true" \
  "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://vault.azure.net" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

# 2. Use the token to read the secret, printing the ID and length but NOT the value
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://kv-lab03-krish.vault.azure.net/secrets/SqlAdminPassword?api-version=7.4" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['id'], '| value length:', len(d['value']))"
```

A secret ID and a length means the VM fetched the password with no credential on disk. A `Forbidden` error means the role assignment is missing or still propagating.

<!-- TODO: keep this section only after running it successfully -->

---

## 🔐 Security Notes
Things worth knowing before treating this as production-ready:

- **"Allow Azure services" is broad.** That setting lets resources from any Azure subscription reach the SQL endpoint (credentials are still required). Prefer a Private Endpoint, or at minimum firewall rules for specific IPs.
- **Public endpoints on both SQL and Key Vault.** Production would use Private Endpoints and Selected networks.
- **The admin is still a SQL login.** The password is now in Key Vault, but `sqladmin` is still a shared credential. Microsoft Entra-only authentication would remove the password entirely.
- **The lab configures access but does not exercise it.** The Bonus section above is how you confirm the VM can actually read the secret.
- **Defender for SQL was skipped** to avoid cost. Enable it for anything real.
- **Rotate secrets.** Setting an expiration date on `SqlAdminPassword` forces regular rotation.

---

## 🛠️ Troubleshooting

| Issue | Likely cause | Fix |
|---|---|---|
| SQL Database creation fails | Server name already taken | Make `sql-server-krish` more unique (add digits) |
| Database is on **Free - General Purpose - Serverless** | Free offer was not removed before creation | Do not change tier afterwards (vCore options can cost $400+/month). Use **CPU percentage** in Phase 6 |
| `vm-web-01` missing in the role-assignment picker | Identity not saved or not propagated | Confirm the Object ID on the Identity page, wait 60 seconds, retry |
| "You are unauthorized to view these contents" on Secrets | Your account has no RBAC role on the vault | Assign yourself **Key Vault Administrator**, wait 1–2 minutes |
| Metrics chart shows no data | New database has not emitted metrics yet | Wait about 5 minutes and refresh |
| Database has the wrong name (for example the server name) | Name field not cleared | Databases cannot be renamed. Delete it, then create a new database on the **existing** server named `sqldb-app` |

---

## 📚 Key Concepts

| Term | Definition |
|---|---|
| PaaS | Managed service: the provider runs the infrastructure |
| IaaS | You manage the VM and everything on it |
| Azure SQL Database | Fully managed relational database based on SQL Server |
| Azure Key Vault | Secure store for secrets, keys and certificates |
| Managed Identity | Azure-managed identity for a resource, no password needed |
| RBAC role assignment | Who + what role + where (scope) |
| Key Vault Secrets User | Built-in role: read secret values only |
| Least privilege | Grant only the minimum access needed |
| Observability | Using metrics, logs and traces to understand health |
| DTU | Bundled measure of compute, memory and I/O for SQL tiers |
| LRS | Data replicated within a single datacenter |

## ✅ Lab Completion Checklist
- [ ] `vm-db-01`, its OS disk and its NIC deleted from `rg-lab02-krish`
- [ ] `vm-web-01` still running in `rg-lab02-krish`
- [ ] `sqldb-app` deployed in `rg-lab03-krish`
- [ ] `kv-lab03-krish` deployed in `rg-lab03-krish`
- [ ] Secret `SqlAdminPassword` created and Enabled
- [ ] System-assigned Managed Identity on `vm-web-01` with an Object ID
- [ ] **Key Vault Secrets User** role assigned to `vm-web-01` (RBAC)
- [ ] Azure Monitor chart showing CPU (or DTU) percentage for `sqldb-app`

## 🧹 Clean Up Resources
*Always clean up unused resources to avoid billing leakage.*

1. **Resource groups** → `rg-lab03-krish` → **Delete resource group** → type the name → **Delete**. This removes the SQL Server, database and Key Vault.
2. Optional: repeat for `rg-lab02-krish`. **Skip this if you plan to continue to Lab 04** and check its prerequisites first.
3. Because soft-delete is on, a deleted Key Vault name stays reserved for the retention period. Purge it under **Key vaults → Manage deleted vaults** if you want to reuse the name.
