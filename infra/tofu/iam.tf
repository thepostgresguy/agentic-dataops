# Phase 2 — IAM for the CodeBuild-hosted GitHub Actions runner.
#
# PERMISSION MODEL (deliberate decision — see steering "Infrastructure Rules"):
# The runner uses AWS-managed PowerUserAccess PLUS a scoped IAM-management
# add-on, rather than per-resource least-privilege. Rationale: later phases keep
# adding new AWS resource types (ECR, AgentCore, Secrets Manager, more IAM, ...)
# and hand-widening a narrow policy every time is too much friction for this
# demo. "Adminish" without full account admin:
#   - PowerUserAccess  = full access to all AWS SERVICES, but NOT IAM
#     user/group management, account, billing, or organizations.
#   - iam-management    = a scoped add-on so later phases can create the IAM
#     roles/policies they need (PowerUser alone cannot).
#
# This is a conscious exception to the charter's least-privilege default,
# accepted for the demo. It is still NOT AdministratorAccess: no IAM user
# management, no account/billing/org control.

resource "aws_iam_role" "codebuild_runner" {
  name = "agentic-dataops-runner-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codebuild.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Project   = "agentic-dataops"
    ManagedBy = "opentofu"
  }
}

# Full access to all AWS services (excludes IAM user/group mgmt, account,
# billing, organizations).
resource "aws_iam_role_policy_attachment" "power_user" {
  role       = aws_iam_role.codebuild_runner.id
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}

# Scoped IAM-management add-on: lets later-phase Tofu create and manage the IAM
# roles/policies the project needs (roles, inline/managed policies, pass-role),
# which PowerUserAccess does NOT grant. Intentionally excludes IAM *user* and
# *group* management, account settings, and organizations.
data "aws_iam_policy_document" "iam_management" {
  statement {
    sid    = "ManageRolesAndPolicies"
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:GetRole",
      "iam:ListRoles",
      "iam:UpdateRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:CreatePolicy",
      "iam:DeletePolicy",
      "iam:GetPolicy",
      "iam:ListPolicies",
      "iam:GetPolicyVersion",
      "iam:CreatePolicyVersion",
      "iam:DeletePolicyVersion",
      "iam:ListPolicyVersions",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:GetRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:PassRole",
      "iam:CreateServiceLinkedRole",
      "iam:CreateInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:ListInstanceProfilesForRole",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "iam_management" {
  name   = "iam-management"
  role   = aws_iam_role.codebuild_runner.id
  policy = data.aws_iam_policy_document.iam_management.json
}

# Scoped Secrets Manager grant — the charter-required least-privilege read on
# the ONE Tiger dev-credentials secret (agentic-dataops/tiger/dev). This is
# distinct from the deliberate broad PowerUserAccess grant above: it is an
# explicit, narrow GetSecretValue on a single ARN, as the charter demands for
# the Tiger secret specifically.
#
# NOTE: var.tiger_secret_arn is NAME-BASED (no random suffix) while the live
# secret ARN carries a trailing random 6-char suffix. If an exact-ARN match is
# required at apply time, override var.tiger_secret_arn with the full ARN
# (including suffix) or use a trailing wildcard on the resource. We keep it
# exact to var.tiger_secret_arn by default and document the caveat rather than
# silently appending a wildcard.
data "aws_iam_policy_document" "tiger_secret_read" {
  statement {
    sid       = "ReadTigerSecret"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.tiger_secret_arn]
  }
}

resource "aws_iam_role_policy" "tiger_secret_read" {
  name   = "tiger-secret-read"
  role   = aws_iam_role.codebuild_runner.id
  policy = data.aws_iam_policy_document.tiger_secret_read.json
}

output "codebuild_runner_role_arn" {
  description = "ARN of the CodeBuild runner's IAM role."
  value       = aws_iam_role.codebuild_runner.arn
}
