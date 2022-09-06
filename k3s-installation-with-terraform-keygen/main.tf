terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 3.59.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}
# olusturacagimiz ec2 intance lara tag vermek icin kulandigimiz variable
variable "ec2_tags" {
  type    = string
  default = "sevda"
}

# olusturacagimiz key file'a tag vermek icin kulandigimiz variable
variable "generated_key_name" {
  type    = string
  default = "sevda-key-k3s"
}

# olusturacagimiz ec2 intance larin user_name leri (ubuntu, ec2-user gibi) icin kulandigimiz variable
variable "ec2_type" {
  type    = string
  default = "ubuntu"
}

# ssh key generate etmek icin kullandigimiz resource
resource "tls_private_key" "k3s-key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# bizim urettigimiz ssh ke ile AWS te bir PEM file olusturmak icin kullandigimiz resource "public_key" kismi
# AWS teki PEM file in adini "var.generated_key_name" variable indan aliyoruz
# kisaca, AWS te bir PEM file olustur, adini "var.generated_key_name" variable indan al
resource "aws_key_pair" "generated_key" {
  key_name   = var.generated_key_name
  public_key = tls_private_key.k3s-key.public_key_openssh
  tags = {
    Name = "aws${var.generated_key_name}"
  }
}

#  "local_file" resource'u ile terraform'u apply yaptigimiz klasorun icerisinde bir "var.generated_key_name" den aldigimiz isim ile bir PEM file olusuturuyoruz, olusturdugumuz PEM file in icerisine de  
resource "local_file" "ssh_key" {
  filename = "${aws_key_pair.generated_key.key_name}.pem"
  content  = tls_private_key.k3s-key.private_key_pem #olusuturdugumuz PEM file in icerisine urettigimiz ssh key i yaziyoruz
  provisioner "local-exec" {
    command = "chmod 400 ./${var.generated_key_name}.pem" # chmod 400 iel PEM file i sadece read only yapiyoruz
  }
}

resource "aws_instance" "master" {
  ami                    = "ami-08d4ac5b634553e16"
  key_name               = var.generated_key_name #master ec2 ya eklyecegimiz KEY file in adi
  vpc_security_group_ids = [aws_security_group.k3s_server.id] #security group un adi, "sec-group-stable.tf" file indan aliyoruz
  instance_type          = "t3a.medium"
  user_data = base64encode(templatefile("${path.module}/server-userdata.tmpl", { #user_data yi hangi file dan alacagini belirtiyoruz
    token = random_password.k3s_cluster_secret.result #token'in degerini "cluster-token.tf" icerisindeki random_password resource'undan aliyor
  })) # token = shared secret used to join a server or agent to a cluster

  tags = { #ec2 instance a bir tag veriyoruz
    Name = "k3sServer${var.ec2_tags}"
  }
  # depends_on ile bagimlilik olusturup once PEM file in olusturulmasini beklemesini soyluyoruz
  depends_on = [aws_key_pair.generated_key]
}

resource "aws_instance" "worker" {
  ami                    = "ami-08d4ac5b634553e16"
  key_name               = var.generated_key_name
  vpc_security_group_ids = [aws_security_group.k3s_agent.id]
  instance_type          = "t3a.medium"
  
  user_data = base64encode(templatefile("${path.module}/agent-userdata.tmpl", { #"agent-userdata.tmpl" icerisindeki variable lara hangi degerlerin verilecegini asagidaki host ve token ile belirliyoruz
    host  = aws_instance.master.private_ip,
    token = random_password.k3s_cluster_secret.result
  }))
  
  #once master instance olusmasini bekle diyoruz
  depends_on = [aws_instance.master]
  
  #worker a verecegimiz tag
  tags = {
    Name = "k3sWorker${var.ec2_tags}"
  }
}

# ekrana cikti olarak master instance a ssh baglantisi icin gerekli olan komutu yazdiriyoruz 
output "ssh_master" {
  description = "URL of ssh to Master"
  value       = "ssh -i ${var.generated_key_name}.pem ${var.ec2_type}@${aws_instance.master.public_ip}"
}

# ekrana cikti olarak WORKER instance a ssh baglantisi icin gerekli olan komutu yazdiriyoruz
output "ssh_worker" {
  description = "URL of ssh to Worker"
  value       = "ssh -i ${var.generated_key_name}.pem ${var.ec2_type}@${aws_instance.worker.public_ip}"
}