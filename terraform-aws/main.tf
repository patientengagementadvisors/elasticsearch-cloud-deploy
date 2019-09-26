provider "aws" {
  region = var.aws_region
}

resource "random_string" "vm-login-password" {
  length           = 16
  special          = true
  override_special = "!@#%&-_"
}

data "aws_availability_zones" "available" {
}

##############################################################################
# Elasticsearch
##############################################################################

resource "aws_security_group" "elasticsearch_security_group" {
  name        = "elasticsearch-${var.es_cluster}-security-group"
  description = "Elasticsearch ports with ssh"
  vpc_id      = var.vpc_id

  tags = {
    Name    = "${var.es_cluster}-elasticsearch"
    cluster = var.es_cluster
  }

  # ssh access from everywhere
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # inter-cluster communication over ports 9200-9400
  ingress {
    from_port = 9200
    to_port   = 9400
    protocol  = "tcp"
    self      = true
  }

  # allow inter-cluster ping
  ingress {
    from_port = 8
    to_port   = 0
    protocol  = "icmp"
    self      = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "elasticsearch_clients_security_group" {
  name        = "elasticsearch-${var.es_cluster}-clients-security-group"
  description = "Kibana HTTP access from outside"
  vpc_id      = var.vpc_id

  tags = {
    Name    = "${var.es_cluster}-kibana"
    cluster = var.es_cluster
  }

  # allow HTTP access to client nodes via ports 8080 and 80 (ELB)
  # better to disable, and either way always password protect!
  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  # allow HTTP access to client nodes via port 3000 for Grafana which has it's own login screen
  ingress {
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_lb" "es_client_lb" {
  // Only create an ELB if it's not a single-node configuration
  count = var.masters_count == "0" && var.datas_count == "0" ? "0" : "1"

  name            = format("%s-client-lb", var.es_cluster)
  security_groups = [aws_security_group.elasticsearch_clients_security_group.id]
  subnets = coalescelist(
    var.clients_subnet_ids,
    [data.aws_subnet_ids.selected.ids],
  )
  internal = var.public_facing == "true" ? "false" : "true"
  load_balancer_type = "application"
  idle_timeout                = 400
  enable_deletion_protection = false

//  access_logs {
//    bucket  = "${aws_s3_bucket.lb_logs.bucket}"
//    prefix  = "test-lb"
//    enabled = true
//  }

  tags = {
    Name = format("%s-client-lb", var.es_cluster)
  }
}

resource "aws_lb_target_group" "es_client_lb_tg8080" {
  name     = format("%s-client-lb-tg-443", var.es_cluster)
  port     = 8080
  protocol = "HTTP"
  vpc_id   = var.vpc_id
  target_type = "instance"

  health_check {
    path = "/status"
  }
}

resource "aws_lb_target_group" "es_client_lb_tg3000" {
  name     = format("%s-client-lb-tg-3000", var.es_cluster)
  port     = 3000
  protocol = "HTTP"
  vpc_id   = var.vpc_id
  target_type = "instance"

  health_check {
    path = "/login"
  }
}

resource "aws_lb_target_group" "es_client_lb_tg9200" {
  name     = format("%s-client-lb-tg-9200", var.es_cluster)
  port     = 9200
  protocol = "HTTP"
  vpc_id   = var.vpc_id
  target_type = "instance"

  health_check {
    path = "/es"
  }
}

data "aws_instances" "clients" {
  depends_on = [ "aws_autoscaling_group.client_nodes" ]
  instance_tags = {
    Name                  = format("%s-client-node", var.es_cluster)
  }
}

data "aws_instances" "masters" {
  depends_on = [ "aws_autoscaling_group.master_nodes" ]
  instance_tags = {
    Name                  = format("%s-master-node", var.es_cluster)
  }
}

resource "aws_lb_target_group_attachment" "aws-lb-tg-attach-3000" {
  count            = var.clients_count
  target_group_arn = aws_lb_target_group.es_client_lb_tg3000.arn
  target_id        = data.aws_instances.clients.ids[count.index]
  port             = 3000
}

resource "aws_lb_target_group_attachment" "aws-lb-tg-attach-8080" {
  count            = var.clients_count
  target_group_arn = aws_lb_target_group.es_client_lb_tg8080.arn
  target_id        = data.aws_instances.clients.ids[count.index]
  port             = 8080
}

resource "aws_lb_target_group_attachment" "aws-lb-tg-attach-9200" {
  count            = var.clients_count
  target_group_arn = aws_lb_target_group.es_client_lb_tg9200.arn
  target_id        = data.aws_instances.masters.ids[count.index]
  port             = 9200
}

resource "aws_lb_listener" "es_lb_listener_80" {
  count = var.masters_count == "0" && var.datas_count == "0" ? "0" : "1"
  load_balancer_arn = aws_lb.es_client_lb[count.index].arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = var.lb_port
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_listener" "es_lb_listener_443" {
  count = var.masters_count == "0" && var.datas_count == "0" ? "0" : "1"
  load_balancer_arn = aws_lb.es_client_lb[count.index].arn
  port              = var.lb_port
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-2016-08"
  certificate_arn   = var.lb_ssl_cert

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.es_client_lb_tg8080.arn
  }
}

resource "aws_lb_listener" "es_lb_listener_3000" {
  count = var.masters_count == "0" && var.datas_count == "0" ? "0" : "1"
  load_balancer_arn = aws_lb.es_client_lb[count.index].arn
  port              = 3000
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-2016-08"
  certificate_arn   = var.lb_ssl_cert

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.es_client_lb_tg3000.arn
  }
}

resource "aws_lb_listener" "es_lb_listener_9200" {
  count = var.masters_count == "0" && var.datas_count == "0" ? "0" : "1"
  load_balancer_arn = aws_lb.es_client_lb[count.index].arn
  port              = 9200
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-2016-08"
  certificate_arn   = var.lb_ssl_cert

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.es_client_lb_tg9200.arn
  }
}

resource "aws_route53_record" "www" {

  count = var.masters_count == "0" && var.datas_count == "0" ? "0" : "1"

  zone_id = var.hosted_zone_id
  name    = "${var.es_cluster}.backend.patientengagementadvisors.com"
  type    = "A"

  alias {
    name                   = aws_lb.es_client_lb[count.index].dns_name
    zone_id                = aws_lb.es_client_lb[count.index].zone_id
    evaluate_target_health = true
  }
}