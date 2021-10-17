terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 2.65"
    }
  }

  required_version = ">= 0.14.9"
}

provider "azurerm" {
  features {}
}

resource "azurerm_resource_group" "rg" {
  name     = "mba-ICC-ResourceGroup"
  location = "westus2"
}

resource "azurerm_virtual_network" "mba-ICC-Network" {
  name                = "mba-ICC-virtualNetwork"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"]
}

resource "azurerm_subnet" "mba-ICC-Subnet" {
  name                 = "mba-ICC-internal"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.mba-ICC-Network.name
  address_prefixes     = ["10.0.2.0/24"]
}

resource "azurerm_public_ip" "mba-ICC-PublicIp" {
  name                = "mba-ICC-PublicIp"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  allocation_method   = "Static"
}

resource "azurerm_network_interface" "mba-ICC-Nic" {
  name                = "mba-ICC-nic"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "mba-ICC-internal"
    subnet_id                     = azurerm_subnet.mba-ICC-Subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.mba-ICC-PublicIp.id
  }
}

resource "azurerm_network_security_group" "mba-ICC-NetworkSecGroup" {
  name                = "mba-ICC-SecurityGroup"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  security_rule {
    name                       = "ssh"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "mysql"
    priority                   = 1002
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3306"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
    }
}

resource "azurerm_network_interface_security_group_association" "mba-ICC-AssociateNTinSG" {
    network_interface_id      = azurerm_network_interface.mba-ICC-Nic.id
    network_security_group_id = azurerm_network_security_group.mba-ICC-NetworkSecGroup.id
}

resource "azurerm_storage_account" "sanmysql" {
  name                     = "stomysql"
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}


resource "azurerm_linux_virtual_machine" "mba-ICC-VmMysql" {
    name                  = "vmmysql"
    location              = azurerm_resource_group.rg.location
    resource_group_name   = azurerm_resource_group.rg.name
    network_interface_ids = [azurerm_network_interface.mba-ICC-Nic.id]
    size                  = "Standard_DS1_v2"

    os_disk {
        name              = "myOsDiskMySQL"
        caching           = "ReadWrite"
        storage_account_type = "Premium_LRS"
    }

    source_image_reference {
        publisher = "Canonical"
        offer     = "UbuntuServer"
        sku       = "18.04-LTS"
        version   = "latest"
    }

    computer_name  = "serverDB"
    admin_username = var.user
    admin_password = var.password
    disable_password_authentication = false

    boot_diagnostics {
        storage_account_uri = azurerm_storage_account.sanmysql.primary_blob_endpoint
    }

    depends_on = [ azurerm_resource_group.rg ]
}

output "public_ip_address_mysql" {
    value = azurerm_public_ip.mba-ICC-PublicIp.ip_address
}

resource "time_sleep" "wait_30_seconds" {
  depends_on = [azurerm_linux_virtual_machine.mba-ICC-VmMysql]
  create_duration = "30s"
}

resource "null_resource" "upload_db" {
  provisioner "file" {
  connection {
    type = "ssh"
    user = var.user
    password = var.password
    host = azurerm_public_ip.mba-ICC-PublicIp.ip_address
  }
  source = "mysql"
  destination = "/home/azure-user"
}

    depends_on = [ time_sleep.wait_30_seconds ]
}

resource "null_resource" "deploy_db" {
    triggers = {
        order = null_resource.upload_db.id
    }
    provisioner "remote-exec" {
        connection {
            type = "ssh"
            user = var.user
            password = var.password
            host = azurerm_public_ip.mba-ICC-PublicIp.ip_address
        }
        inline = [
            "sudo apt-get update",
            "sudo apt-get install -y mysql-server-5.7",
            "sudo mysql < /home/azure-user/mysql/user.sql",
            "sudo cp -f /home/azure-user/mysql/mysqld.cnf /etc/mysql/mysql.conf.d/mysqld.cnf",
            "sudo service mysql restart",
            "sleep 20",
        ]
    }
}