provider "aws" {
  region = "eu-west-2"

  default_tags {
    tags = {
      owner = "andrea"
      Name = "andrea_pangolin"
    }
  }
}

data "aws_ami" "suse" {
  most_recent = true

  filter {
    name   = "name"
    values = ["suse-sles-16-0-*-hvm-ssd-x86_64"]
  }

  filter {
    name   = "description"
    values = ["SUSE Linux Enterprise Server 16.0 (HVM, 64-bit, SSD-Backed)"]
  }

  owners = ["013907871322"] # SUSE
}

resource "aws_instance" "pangolin" {
  ami           = data.aws_ami.suse.id
  instance_type = "t3.small"
  availability_zone = "eu-west-2a"
  key_name = "amazzotti"
  security_groups = [ "TestAllowAll" ] # TODO: create ad hoc SG
  # user_data = templatefile("${path.module}/pangolin_init.sh",
  # {
  #   owner_email=var.owner_email
  #   pangolin_server_secret=var.pangolin_server_secret
  #   pangolin_device=var.pangolin_device
  # })
}

resource "aws_eip_association" "pangolin_ip_assoc" {
  instance_id   = aws_instance.pangolin.id
  allocation_id = aws_eip.pangolin.id
}

resource "aws_eip" "pangolin" {
  domain = "vpc"
}

resource "aws_ebs_volume" "pangolin" { # TODO: create snapshot policy
  availability_zone = "eu-west-2a"
  size              = 1
}

resource "aws_volume_attachment" "pangolin_ebs_att" {
  device_name = "/dev/sdh"
  volume_id   = aws_ebs_volume.pangolin.id
  instance_id = aws_instance.pangolin.id
}
