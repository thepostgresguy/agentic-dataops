# Secrets Manager secret holding the app's database connection string.
#
# Tofu creates the CONTAINER ONLY — no value. You populate the DSN out-of-band
# so the connection string (with its password) never touches Tofu code or
# state:
#
#   aws secretsmanager put-secret-value \
#     --secret-id agentic-dataops/app/database-url \
#     --secret-string 'postgresql://tsdbadmin:<password>@<host>:<port>/tsdb?sslmode=require' \
#     --region us-east-1
#
# The app reads this single value into DATABASE_URL (what Prisma expects:
# datasource db { url = env("DATABASE_URL") }). The password comes from your
# Tiger keyring — never committed.

resource "aws_secretsmanager_secret" "app_database_url" {
  name        = "agentic-dataops/app/database-url"
  description = "Full DATABASE_URL (Postgres DSN) for the app's Tiger Cloud dev service."

  tags = {
    Project   = "agentic-dataops"
    Purpose   = "app-database-url"
    ManagedBy = "opentofu"
  }
}

output "app_database_url_secret_arn" {
  description = "ARN of the app DATABASE_URL secret. Populate its value with the AWS CLI (see app_db_secret.tf)."
  value       = aws_secretsmanager_secret.app_database_url.arn
}
