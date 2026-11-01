# Linux App Service private networking plan

**Status:** Design only — no Azure resources have been created.

## Goal

Host an Azure App Service web app with outbound access to a regional virtual network and private-only inbound access through an App Service private endpoint. The original design targets Linux; the reusable deployment template also supports Windows when an appropriate runtime is provided. Private DNS should let clients on the virtual network use the app's normal `*.azurewebsites.net` hostname.

## Assumptions and decisions

- The example resource group name is `rg-appservice-01`. This is an example, not a check that the Azure resource group exists.
- The App Service plan, app, VNet, and subnets will be in one Azure region. The region and subscription are not specified and remain to be selected.
- Use a **Standard S1 Linux plan** for a cost-conscious non-production or modest workload. Choose **Premium v3 (P1v3 or an appropriately sized SKU)** when production capacity, scale, or Premium-tier features justify the added cost. Confirm workload sizing, availability, and regional SKU availability before deployment.
- The address ranges below are examples only. Check them against existing VNet, peered-VNet, VPN, and on-premises address spaces before use.

## Proposed architecture

```text
Clients on VNet / peered network / VPN
          |
          | DNS: <app>.azurewebsites.net
          | resolves through privatelink.azurewebsites.net
          v
Private DNS zone: privatelink.azurewebsites.net
          |
          | A record -> private endpoint IP
          v
VNet: vnet-appservice-01 (<region>, example 10.40.0.0/16)
  +-- snet-appservice-integration (example 10.40.1.0/26)
  |     Delegated to Microsoft.Web/serverFarms
  |     Attached to the App Service regional VNet integration
  |
  +-- snet-appservice-private-endpoint (example 10.40.2.0/27)
        Not delegated; hosts the App Service private endpoint
          |
          v
Linux Web App on App Service plan (Standard S1 or Premium v3)
```

The private endpoint and VNet integration serve different directions: the private endpoint handles inbound connections to the app; VNet integration provides outbound connectivity from the app. They must use separate subnets.

## Components and configuration

| Component | Proposed configuration |
|---|---|
| App Service plan | Linux; Standard S1 for modest/non-production use or Premium v3 when the workload needs its capacity/features. Size after workload review. |
| Web app | Linux App Service; enable HTTPS-only. Use the platform hostname unless a custom domain is later required. |
| VNet | `vnet-appservice-01` in the same region as the App Service plan for regional integration. Confirm its address space does not overlap connected networks. |
| Integration subnet | Dedicated subnet, delegated to `Microsoft.Web/serverFarms`, used only for App Service VNet integration. `/26` is a recommended starting point for a single plan to allow scale and platform operations; validate against planned maximum instances and current service limits. |
| Private endpoint subnet | Separate from the integration subnet, with no App Service delegation. Allocate sufficient free IPs for the private endpoint and any future endpoints. |
| Private endpoint | Target the web app's `sites` subresource and approve the connection. Associate a private DNS zone group with the endpoint. |
| Private DNS | Create `privatelink.azurewebsites.net` and link it to the VNet. Keep zone auto-registration off; the private endpoint DNS zone group manages endpoint records. |
| Public access | After private connectivity and DNS are validated, disable public network access on the web app. |

### DNS and client reachability

- The private endpoint DNS zone group should add the app's private A record and, when applicable, the SCM/Kudu hostname record.
- Clients should use the normal hostname, `<app>.azurewebsites.net`; DNS follows the public CNAME chain and the linked private zone resolves the private-link name to the endpoint's private IP. This preserves the hostname expected by the App Service certificate.
- For clients outside the VNet, provide private network routing and DNS resolution as well. For on-premises or hub/spoke clients, link the zone to the relevant VNets or configure DNS forwarding (for example, with Azure DNS Private Resolver).
- If private deployments or Kudu access are needed, verify the SCM hostname resolves to the private endpoint from the deployment network.

### Outbound networking

Regional VNet integration is for app-initiated outbound traffic; it does not make the app privately reachable inbound. By default, private destinations reachable through the VNet use the integration subnet. Route all app traffic through the VNet only if the design needs centralized egress control, inspection, or a NAT Gateway; document and validate routes, DNS, and required outbound dependencies first.

## Implementation sequence (for a later deployment)

1. Confirm subscription, region, resource-group availability, address-space non-overlap, workload size, and required client networks.
2. Create or select the VNet and create the dedicated integration and private-endpoint subnets with the required delegation and separation.
3. Create the Linux App Service plan and web app.
4. Configure regional VNet integration using the delegated integration subnet.
5. Create the private DNS zone and VNet link.
6. Create the app private endpoint in the separate subnet and attach a private DNS zone group.
7. Test name resolution and HTTPS from an intended private client; test SCM access if needed.
8. Disable public network access and repeat the private-client tests. Confirm public clients cannot reach the app.

## Acceptance checks

- App Service plan and VNet are in the same region; integration is regional and uses the delegated integration subnet.
- The private endpoint is in a different subnet and has an approved connection.
- From a VNet-connected client, `<app>.azurewebsites.net` resolves to the private endpoint IP and HTTPS succeeds.
- If used, `<app>.scm.azurewebsites.net` resolves privately and deployment/Kudu access works from the intended private network.
- Public network access is disabled and the app is not reachable over its public endpoint.
- App outbound connectivity to required private dependencies works, and any route-all/egress controls behave as intended.

## Out of scope

This plan does not create resources, select a final SKU, define application runtime/deployment settings, configure a custom domain, establish hub/on-premises connectivity, or generate Bicep/Terraform/ARM files.

## References

- [Integrate your app with an Azure virtual network](https://learn.microsoft.com/en-us/azure/app-service/overview-vnet-integration)
- [Use private endpoints for apps](https://learn.microsoft.com/en-us/azure/app-service/overview-private-endpoint)
