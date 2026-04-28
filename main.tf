provider "aws" {
  region = "eu-west-2"

  default_tags {
    tags = {
      owner = "andrea"
      Name = "andrea_pangolin"
    }
  }
}

data "aws_ami" "debian" {
  most_recent = true

  filter {
    name   = "name"
    values = ["debian-13-amd64*"]
  }

  owners = ["136693071363"] 
}

resource "aws_instance" "pangolin" {
  ami           = data.aws_ami.debian.id
  instance_type = "t3.micro"
  availability_zone = "eu-west-2a"
  key_name = "amazzotti"
  security_groups = [ aws_security_group.allow_pangolin.name ]
  user_data = templatefile("${path.module}/pangolin_init.sh",
  {
    owner_email="andrea.mazzotti@suse.com"
    pangolin_server_secret="just4now"
    pangolin_device="/dev/nvme1n1"
  })
}

resource "aws_eip_association" "pangolin_ip_assoc" {
  instance_id   = aws_instance.pangolin.id
  allocation_id = aws_eip.pangolin.id
}

resource "aws_volume_attachment" "pangolin_ebs_att" {
  device_name = "/dev/sdh"
  volume_id   = aws_ebs_volume.pangolin.id
  instance_id = aws_instance.pangolin.id
}
