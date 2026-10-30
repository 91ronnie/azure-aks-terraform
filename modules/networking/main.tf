# Networking for a single-region AKS lab.
#
# Address plan (defaults, see docs/architecture.md#ip-plan):
#   VNet               10.40.0.0/16
#     snet-aks-nodes   10.40.0.0/22   node NICs only (Azure CNI Overlay: pods do NOT use VNet IPs)
#     snet-postgres    10.40.12.0/28  delegated to PostgreSQL Flexible Server (optional)
#     snet-mysql       10.40.13.0/28  delegated to MySQL Flexible Server (optional, FrontRow API)
#     snet-private-endpoints 10.40.8.0/24  private endpoints (optional; Managed Redis)
#     (reserved)       10.40.16.0/28  future API server VNet integration
#   Pod CIDR (overlay) 10.244.0.0/16  not routable in the VNet, configured on AKS
#   Service CIDR       172.16.0.0/16  cluster-internal, configured on AKS
#
# Two static Standard public IPs are created here so that their addresses are
# owned by Terraform (not by the AKS-managed node resource group). They survive
# cluster re-creation and can be allow-listed (egress) or put in DNS (ingress).

resource "azurerm_virtual_network" "this" {
  name                = "vnet-${var.name_prefix}"
  location            = var.location
  resource_group_name = var.resource_group_name
  address_space       = [var.vnet_cidr]
  tags                = var.tags
}

resource "azurerm_subnet" "aks_nodes" {
  name                 = "snet-aks-nodes"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.aks_nodes_subnet_cidr]

  # No implicit Azure "default outbound access": all egress must go through the
  # AKS Standard Load Balancer outbound rule and its static egress IP.
  default_outbound_access_enabled = false

  # Key Vault traffic from the nodes stays on the Azure backbone and is
  # identified by this subnet, which the Key Vault firewall allows. No cost.
  service_endpoint {
    service = "Microsoft.KeyVault"
  }
}

resource "azurerm_network_security_group" "aks_nodes" {
  name                = "nsg-${var.name_prefix}-aks-nodes"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  # The default NSG rules already allow VNet-internal traffic and Azure Load
  # Balancer health probes, and deny all other inbound traffic from the Internet.
  # The only Internet-facing service is the ingress controller on 80/443.
  security_rule {
    name                       = "allow-ingress-http-https"
    priority                   = 200
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["80", "443"]
    source_address_prefixes    = var.ingress_allowed_source_prefixes
    destination_address_prefix = "*"
    description                = "HTTP(S) to the ingress controller via the Standard Load Balancer"
  }
}

resource "azurerm_subnet_network_security_group_association" "aks_nodes" {
  subnet_id                 = azurerm_subnet.aks_nodes.id
  network_security_group_id = azurerm_network_security_group.aks_nodes.id
}

# Delegated subnet for Azure Database for PostgreSQL Flexible Server with
# private (VNet-integrated) access. Only created when a CIDR is given.
resource "azurerm_subnet" "postgres" {
  count = var.postgres_subnet_cidr == null ? 0 : 1

  name                            = "snet-postgres"
  resource_group_name             = var.resource_group_name
  virtual_network_name            = azurerm_virtual_network.this.name
  address_prefixes                = [var.postgres_subnet_cidr]
  default_outbound_access_enabled = false

  delegation {
    name = "postgres-flexible-server"
    service_delegation {
      name    = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

# Only the AKS nodes may reach PostgreSQL. Overlay pod traffic leaves the node
# with the node's IP, so the node subnet is the right source.
resource "azurerm_network_security_group" "postgres" {
  count = var.postgres_subnet_cidr == null ? 0 : 1

  name                = "nsg-${var.name_prefix}-postgres"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  security_rule {
    name                       = "allow-postgres-from-aks-nodes"
    priority                   = 200
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "5432"
    source_address_prefix      = var.aks_nodes_subnet_cidr
    destination_address_prefix = var.postgres_subnet_cidr
    description                = "PostgreSQL from AKS nodes (pods are SNATed to node IPs)"
  }

  security_rule {
    name                       = "allow-intra-subnet"
    priority                   = 210
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = var.postgres_subnet_cidr
    destination_address_prefix = var.postgres_subnet_cidr
    description                = "Server-internal traffic (e.g. high availability)"
  }

  security_rule {
    name                       = "deny-other-vnet-inbound"
    priority                   = 4000
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "*"
    description                = "Override the default AllowVnetInBound"
  }
}

resource "azurerm_subnet_network_security_group_association" "postgres" {
  count = var.postgres_subnet_cidr == null ? 0 : 1

  subnet_id                 = azurerm_subnet.postgres[0].id
  network_security_group_id = azurerm_network_security_group.postgres[0].id
}

# Delegated subnet for Azure Database for MySQL Flexible Server (FrontRow API),
# same pattern as PostgreSQL above. Only created when a CIDR is given.
resource "azurerm_subnet" "mysql" {
  count = var.mysql_subnet_cidr == null ? 0 : 1

  name                            = "snet-mysql"
  resource_group_name             = var.resource_group_name
  virtual_network_name            = azurerm_virtual_network.this.name
  address_prefixes                = [var.mysql_subnet_cidr]
  default_outbound_access_enabled = false

  delegation {
    name = "mysql-flexible-server"
    service_delegation {
      name    = "Microsoft.DBforMySQL/flexibleServers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_network_security_group" "mysql" {
  count = var.mysql_subnet_cidr == null ? 0 : 1

  name                = "nsg-${var.name_prefix}-mysql"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  security_rule {
    name                       = "allow-mysql-from-aks-nodes"
    priority                   = 200
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3306"
    source_address_prefix      = var.aks_nodes_subnet_cidr
    destination_address_prefix = var.mysql_subnet_cidr
    description                = "MySQL from AKS nodes (pods are SNATed to node IPs)"
  }

  security_rule {
    name                       = "allow-intra-subnet"
    priority                   = 210
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = var.mysql_subnet_cidr
    destination_address_prefix = var.mysql_subnet_cidr
    description                = "Server-internal traffic (e.g. high availability)"
  }

  security_rule {
    name                       = "deny-other-vnet-inbound"
    priority                   = 4000
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "*"
    description                = "Override the default AllowVnetInBound"
  }
}

resource "azurerm_subnet_network_security_group_association" "mysql" {
  count = var.mysql_subnet_cidr == null ? 0 : 1

  subnet_id                 = azurerm_subnet.mysql[0].id
  network_security_group_id = azurerm_network_security_group.mysql[0].id
}

# Private endpoints (Azure Managed Redis). NSGs apply to private endpoints only
# with network policies enabled, which is set here so the rule below is enforced.
resource "azurerm_subnet" "private_endpoints" {
  count = var.private_endpoints_subnet_cidr == null ? 0 : 1

  name                              = "snet-private-endpoints"
  resource_group_name               = var.resource_group_name
  virtual_network_name              = azurerm_virtual_network.this.name
  address_prefixes                  = [var.private_endpoints_subnet_cidr]
  default_outbound_access_enabled   = false
  private_endpoint_network_policies = "Enabled"
}

resource "azurerm_network_security_group" "private_endpoints" {
  count = var.private_endpoints_subnet_cidr == null ? 0 : 1

  name                = "nsg-${var.name_prefix}-private-endpoints"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  security_rule {
    name                       = "allow-redis-from-aks-nodes"
    priority                   = 200
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "10000"
    source_address_prefix      = var.aks_nodes_subnet_cidr
    destination_address_prefix = var.private_endpoints_subnet_cidr
    description                = "Azure Managed Redis (TLS, port 10000) from AKS nodes"
  }

  security_rule {
    name                       = "deny-other-vnet-inbound"
    priority                   = 4000
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "*"
    description                = "Override the default AllowVnetInBound"
  }
}

resource "azurerm_subnet_network_security_group_association" "private_endpoints" {
  count = var.private_endpoints_subnet_cidr == null ? 0 : 1

  subnet_id                 = azurerm_subnet.private_endpoints[0].id
  network_security_group_id = azurerm_network_security_group.private_endpoints[0].id
}

resource "azurerm_public_ip" "ingress" {
  name                = "pip-${var.name_prefix}-ingress"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  domain_name_label   = var.ingress_domain_name_label
  tags                = var.tags
}

resource "azurerm_public_ip" "egress" {
  name                = "pip-${var.name_prefix}-egress"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}
