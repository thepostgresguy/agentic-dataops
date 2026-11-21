# ACM certificate for the app domain, DNS-validated.
#
# DNS records are created in a SEPARATE repo (Cloudflare), by you. So:
#   1. First apply creates the cert in PENDING_VALIDATION and exposes the
#      validation CNAME via the `acm_validation_record` output.
#   2. You create that CNAME in Cloudflare (DNS-only / grey cloud).
#   3. The aws_acm_certificate_validation resource below WAITS until ACM sees
#      the record and issues the cert. (On the first apply, before the record
#      exists, this wait will time out — that is expected; re-run apply after
#      you've added the DNS record, or raise the timeout.)
#
# The ALB HTTPS listener (alb.tf) depends on the validated cert.

resource "aws_acm_certificate" "app" {
  domain_name       = var.app_domain
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Project   = "agentic-dataops"
    ManagedBy = "opentofu"
  }
}

# Expose the DNS validation record for you to create in Cloudflare.
output "acm_validation_record" {
  description = "CREATE THIS in Cloudflare (DNS-only): the ACM validation CNAME."
  value = {
    for dvo in aws_acm_certificate.app.domain_validation_options :
    dvo.domain_name => {
      type   = dvo.resource_record_type
      name   = dvo.resource_record_name
      target = dvo.resource_record_value
    }
  }
}

# Waits for ACM to validate once the DNS record exists. Note: no
# validation_record_fqdns here because the records live in an external
# (Cloudflare) zone we don't manage from this Tofu.
resource "aws_acm_certificate_validation" "app" {
  certificate_arn = aws_acm_certificate.app.arn

  timeouts {
    create = "15m"
  }
}
