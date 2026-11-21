# Public Application Load Balancer fronting the app.
#
# Cloudflare is DNS-only (grey cloud) for overflow.thepostgresguy.com, so the
# ALB terminates TLS with the ACM cert. HTTP redirects to HTTPS.

# --- Security groups ---

resource "aws_security_group" "alb" {
  name        = "agentic-dataops-alb"
  description = "ALB ingress 80/443 from internet"
  vpc_id      = var.rag_peer_vpc_id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Project = "agentic-dataops", ManagedBy = "opentofu" }
}

resource "aws_security_group" "app" {
  name        = "agentic-dataops-app"
  description = "App task: ingress from ALB on the container port only"
  vpc_id      = var.rag_peer_vpc_id

  ingress {
    description     = "From ALB"
    from_port       = var.app_container_port
    to_port         = var.app_container_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"] # pull image, reach Tiger Cloud
  }

  tags = { Project = "agentic-dataops", ManagedBy = "opentofu" }
}

# --- ALB + target group ---

resource "aws_lb" "app" {
  name               = "agentic-dataops-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.app_public_subnet_ids

  tags = { Project = "agentic-dataops", ManagedBy = "opentofu" }
}

resource "aws_lb_target_group" "app" {
  name        = "agentic-dataops-app"
  port        = var.app_container_port
  protocol    = "HTTP"
  vpc_id      = var.rag_peer_vpc_id
  target_type = "ip" # Fargate uses awsvpc/ip targets

  health_check {
    path                = "/health"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = { Project = "agentic-dataops", ManagedBy = "opentofu" }
}

# HTTP :80 -> redirect to HTTPS
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

# HTTPS :443 -> app target group, using the validated ACM cert.
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.app.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.app.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

output "alb_dns_name" {
  description = "ALB hostname. CREATE a Cloudflare CNAME: overflow.thepostgresguy.com -> this (DNS-only)."
  value       = aws_lb.app.dns_name
}

output "app_cname_record" {
  description = "CREATE THIS in Cloudflare (DNS-only): the app record."
  value = {
    type   = "CNAME"
    name   = var.app_domain
    target = aws_lb.app.dns_name
    proxy  = "OFF (grey cloud)"
  }
}
