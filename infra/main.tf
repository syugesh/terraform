terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }

    time = {
      source  = "hashicorp/time"
      version = "~> 0.11"
    }
  }
}

provider "aws" {
  region = "ap-south-1"
}

variable "my_ip" {
  description = "Your public IP address in CIDR format"
  type        = string
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]
  
  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
}

resource "aws_security_group" "alb_sg" {
  name   = "simple-alb-sg"
  vpc_id = data.aws_vpc.default.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.my_ip]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "ec2_sg" {
  name   = "simple-ec2-sg"
  vpc_id = data.aws_vpc.default.id

  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "temporary_vm" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = "t3.micro"
  subnet_id              = data.aws_subnets.default.ids[0]
  vpc_security_group_ids = [aws_security_group.ec2_sg.id]

  user_data = <<EOF
#!/bin/bash
yum update -y
yum install -y httpd
systemctl enable httpd
systemctl start httpd
echo "<h1>Temporary Apache Server</h1>" > /var/www/html/index.html
EOF

  tags = {
    Name = "temporary-vm"
  }
}

resource "time_sleep" "wait" {
  depends_on      = [aws_instance.temporary_vm]
  create_duration = "120s"
}

resource "aws_ami_from_instance" "apache_ami" {
  name               = "simple-apache-ami"
  source_instance_id = aws_instance.temporary_vm.id

  depends_on = [time_sleep.wait]
}

resource "aws_ec2_instance_state" "stop_temp_vm" {
  instance_id = aws_instance.temporary_vm.id
  state       = "stopped"
  depends_on = [aws_ami_from_instance.apache_ami]
}

resource "aws_launch_template" "web_template" {
  name_prefix   = "simple-web-template"
  image_id      = aws_ami_from_instance.apache_ami.id
  instance_type = "t3.micro"

  vpc_security_group_ids = [aws_security_group.ec2_sg.id]

  user_data = base64encode(<<EOF
#!/bin/bash
HOSTNAME=$(hostname)
echo "<h1>Web Server from Auto Scaling Group</h1>" > /var/www/html/index.html
echo "<h2>Hostname: $HOSTNAME</h2>" >> /var/www/html/index.html
echo "<p>This server is running behind Load Balancer</p>" >> /var/www/html/index.html
systemctl restart httpd
EOF
  )
}

resource "aws_lb" "alb" {
  name               = "simple-alb"
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = data.aws_subnets.default.ids
}

resource "aws_lb_target_group" "tg" {
  name     = "simple-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default.id

  health_check {
    path     = "/"
    protocol = "HTTP"
    matcher  = "200"
  }
}

resource "aws_lb_listener" "listener" {
  load_balancer_arn = aws_lb.alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg.arn
  }
}

resource "aws_autoscaling_group" "asg" {
  desired_capacity    = 3
  min_size            = 3
  max_size            = 3
  vpc_zone_identifier = data.aws_subnets.default.ids

  target_group_arns = [aws_lb_target_group.tg.arn]
  health_check_type = "ELB"

  launch_template {
    id      = aws_launch_template.web_template.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "asg-web-server"
    propagate_at_launch = true
  }
}

output "load_balancer_url" {
  value = "http://${aws_lb.alb.dns_name}"
}