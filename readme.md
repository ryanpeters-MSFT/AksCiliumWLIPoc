# AKS Purpose-Built Implementation

*This is a purpose-built implementation of AKS with specific features to satisfy a set of requirements, highlighting various new features that support best practices in security, performance, and observability.*

## Summary

## Quickstart

Modify the [setup.ps1](./setup.ps1) script with desired parameters and invoke. Ensure that your user has `Contributor` access to the subscription.

```powershell
# create the cluster and supporting resources
.\setup.ps1
```

The script will provision the resources and output the following:

1. The resource ID of the ALB subnet that needs to be applied to the [apploadbalancer.yaml](./apploadbalancer.yaml) ALB resource to associate the App Gateway to the subnet.
2. The client ID for the UAMI for a service account to be associated with a sample workload (this is separate from the UAMI for ALB). Associate this service account to an optional workload.

Once the ALB resource has been updated with the ALB subnet ID deploy the remaining resources:

```powershell
# deploy the ALB
kubectl apply -f .\apploadbalancer.yaml

# deploy the sample workload
kubectl apply -f .\workload.yaml
```