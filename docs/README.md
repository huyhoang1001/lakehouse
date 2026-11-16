# NT Accelerate Lakehouse — Documentation

This series documents the AWS TechCamp 2022 lakehouse built as Infrastructure-as-Code using Terraform. The lab runs across three days, each adding a layer to the architecture.

| Day | Topic | Status |
|-----|-------|--------|
| [Day 1](./day1-ingestion.md) | Extract data from RDS SQL Server into S3 (bronze layer) using AWS Glue | ✅ Implemented |
| Day 2 | Orchestration — master job, Step Functions, Lambda, SES notifications | 🔜 Planned |
| Day 3 | Transform, gold layer, Redshift migration | 🔜 Planned |

## Repository layout

```
lakehouse/
├── docs/                    ← architecture docs (this folder)
├── infra/                   ← Terraform stack
│   ├── networking.tf        — VPC, security groups, RDS
│   ├── s3.tf                — S3 bucket and artifact uploads
│   ├── iam.tf               — Glue IAM role and policies
│   ├── secrets.tf           — Secrets Manager
│   ├── dynamodb.tf          — DynamoDB control tables + seed data
│   ├── glue.tf              — Glue catalog, connection, crawler
│   ├── glue_jobs.tf         — Glue extraction jobs
│   ├── rds_seed.tf          — RDS seeding via sqlcmd
│   ├── scripts/
│   │   └── batch_seed.py    — fast batch seed helper
│   └── README.md            — deployment guide
└── instruction/             ← original lab source artifacts
```
