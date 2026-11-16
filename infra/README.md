# NT Accelerate Day 1 — Infrastructure

Terraform stack for the NT Accelerate Day 1 lakehouse lab. Provisions an S3 bucket, RDS SQL Server Express instance, Glue jobs, IAM roles, networking, and seeds the Tickit database schema.

---

## Prerequisites

### AWS CLI & Terraform
- [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html)
- [Terraform ≥ 1.5](https://developer.hashicorp.com/terraform/downloads)

### sqlcmd

The `null_resource.db_seed` provisioner runs `sqlcmd` locally to seed the RDS instance with the Tickit schema and data. It must be installed on the machine running `terraform apply`.

**macOS**
```bash
brew install sqlcmd
```
Or via the Microsoft tap:
```bash
brew tap microsoft/mssql-release https://github.com/Microsoft/homebrew-mssql-release
brew update && brew install mssql-tools
```

**Linux (Ubuntu/Debian)**

Install Microsoft's `mssql-tools` apt package. Full instructions: https://docs.microsoft.com/en-us/sql/linux/sql-server-linux-setup-tools

**Windows**

Install [SQL Server Management Studio (SSMS)](https://learn.microsoft.com/en-us/sql/ssms/download-sql-server-management-studio-ssms) or the standalone [sqlcmd utility](https://learn.microsoft.com/en-us/sql/tools/sqlcmd/sqlcmd-utility) from Microsoft.

**Verify the install**
```bash
sqlcmd -?
```

---

## Required variables

Create `infra/terraform.tfvars` from the example below and fill in your values.

| Variable | Description |
|---|---|
| `bucket_name` | Globally unique S3 bucket name (lowercase letters, numbers, hyphens, dots; 3–63 chars) |
| `db_username` | RDS SQL Server master username |
| `db_password` | RDS SQL Server master password (**sensitive** — never commit this file) |
| `source_artifacts_dir` | Local path to the `Day 1 source 3/Day 1 source` folder containing the Glue scripts and S3 assets |

**terraform.tfvars.example**
```hcl
bucket_name          = "my-lakehouse-bucket"
db_username          = "admin"
db_password          = "ChangeMe123!"
source_artifacts_dir = "../instruction/day1/Day 1 source 3/Day 1 source"
```

Optional variables and their defaults are documented in `variables.tf`.

---

## Deployment

1. **Install prerequisites** — AWS CLI, Terraform ≥ 1.5, and `sqlcmd` (see above).

2. **Configure AWS credentials**
   ```bash
   aws configure
   # or export AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_SESSION_TOKEN
   ```

3. **Create your tfvars file**
   ```bash
   cp infra/terraform.tfvars.example infra/terraform.tfvars
   # edit terraform.tfvars with your values
   ```

4. **Initialise Terraform**
   ```bash
   cd infra && terraform init
   ```

5. **Review the plan**
   ```bash
   terraform plan
   ```

6. **Apply**
   ```bash
   terraform apply
   ```
   This provisions all resources and seeds the RDS instance with the Tickit schema and sample data.

---

## Cost control

Stop the RDS instance when not in use to avoid unnecessary charges:
```bash
aws rds stop-db-instance --db-instance-identifier <db-instance-id>
```

Tear down all resources when you are done with the lab:
```bash
terraform destroy
```
