provider "cloudflare" {
  # CLOUDFLARE_API_TOKEN from the traffic GitHub environment. Scope: one zone and one account.
  #   Zone:    Load Balancers Edit, DNS Edit, Zone Settings Edit
  #   Account: Load Balancing: Monitors And Pools Edit, Access: Apps and Policies Edit,
  #            Access: Service Tokens Edit
}
