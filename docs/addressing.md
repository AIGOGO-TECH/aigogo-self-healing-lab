# Addressing and design plan

Written down before the configs, because "ad-hoc addressing with no
documented plan" was the first thing an ISP architect flagged about the
three-node version. Every address below comes from a documentation range
(RFC 5737, RFC 3849) or private space, so nothing here can collide with
anything real if it is ever pasted somewhere it should not be.

## Roles

| Device | Role | Why |
|---|---|---|
| srl1 | core + route reflector | RR pair with srl2, so losing one does not lose iBGP |
| srl2 | core + route reflector | same cluster-id as srl1 |
| srl3 | border / PE, RR client | holds the eBGP session to transit |
| srl4 | transit provider, AS 64500 | a separate administrative domain, not ours |

## Topology

```
          10.255.1.0/31
    srl1 ─────────────── srl2
      │  ╲             ╱  │
      │    ╲         ╱    │
      │      ╲     ╱      │      10.255.1.4/31  (srl1-srl3)
      │        ╲ ╱        │      10.255.1.2/31  (srl2-srl3)
      └──────── srl3 ─────┘
                 ║
                 ║ eBGP, 198.51.100.0/31
                 ║
               srl4   AS 64500
```

A triangle, not a line. The three-node line partitioned the network on any
single failure, which made "self-healing" hollow: there was nothing to
reroute to. With a triangle, IS-IS has a second path and the automation is
repairing intent rather than substituting for redundancy that was never
there.

## Autonomous systems

| ASN | Who |
|---|---|
| 65001 | us (private, RFC 6996) |
| 64500 | the upstream transit provider |

## Addressing

### Loopbacks — 10.255.0.0/24

| Device | IPv4 | IPv6 |
|---|---|---|
| srl1 | 10.255.0.1/32 | 2001:db8:0:255::1/128 |
| srl2 | 10.255.0.2/32 | 2001:db8:0:255::2/128 |
| srl3 | 10.255.0.3/32 | 2001:db8:0:255::3/128 |
| srl4 | 10.255.0.4/32 | 2001:db8:0:255::4/128 |

Router-id and the iBGP transport address are always the loopback, so a
session survives any single link failure.

### Infrastructure point-to-point — 10.255.1.0/24

/31, not /30 (RFC 3021). An ISP does not spend four addresses on a link
that needs two, and SR Linux supports it.

| Link | IPv4 | IPv6 |
|---|---|---|
| srl1 e1-1 ↔ srl2 e1-1 | 10.255.1.0/31 | 2001:db8:0:1::/127 |
| srl2 e1-2 ↔ srl3 e1-1 | 10.255.1.2/31 | 2001:db8:0:1::2/127 |
| srl1 e1-2 ↔ srl3 e1-2 | 10.255.1.4/31 | 2001:db8:0:1::4/127 |

### Management network — 172.30.30.0/24

containerlab's management bridge, which the stack shares.

| Range | Use |
|---|---|
| .2 – .19 | Docker's dynamic pool for the stack's own containers |
| .21 – .24 | the routers, pinned in `clab/topo.yml` |
| **.30** | **reserved: the syslog collector** |

The routers are pinned because containerlab reassigns addresses on every
redeploy, which silently broke every proxy-minion three times before it was
noticed. The syslog collector is pinned for the same reason from the other
direction: the devices are configured to send there, and a syslog
destination that moves stops working on the next restart. .30 sits clear of
both the dynamic pool, which grows upward from .2, and the device range.

### The transit link — 198.51.100.0/31

Provider space, from the provider's block. We are the customer on this
link and do not own the addressing, which is why it is not in 10.255/16.

| End | IPv4 | IPv6 |
|---|---|---|
| srl3 e1-3 (us) | 198.51.100.1/31 | 2001:db8:ffff::1/127 |
| srl4 e1-1 (them) | 198.51.100.0/31 | 2001:db8:ffff::/127 |

### What we originate — 203.0.113.0/24

Customer-facing space, announced to transit as a single aggregate. Carved
into /26s per site so there is something real for a prefix-list to filter
and something real for a route policy to get wrong.

| Prefix | Use |
|---|---|
| 203.0.113.0/24 | the aggregate we announce to AS 64500 |
| 203.0.113.0/26 | site A customers |
| 203.0.113.64/26 | site B customers |

IPv6: 2001:db8:100::/48 announced as one aggregate.

### What transit sends us

A default route plus a handful of more-specifics, so that "did we actually
receive routes" is a question with a visible answer — unlike the three-node
version, where both iBGP sessions sat established at [0/0/0] forever.

## Protocol design

| | |
|---|---|
| IGP | IS-IS level 2 only, wide metrics, hello-padding adaptive |
| IGP auth | keychain, so an unauthenticated neighbour cannot join |
| overload-bit | set on boot, cleared after convergence, so a booting node is not used for transit |
| BFD | on every IS-IS adjacency and the eBGP session |
| iBGP | full-mesh-free: srl1+srl2 are RRs in one cluster, srl3 is a client |
| eBGP | srl3 to AS 64500, with import and export policy and a prefix limit |
| IPv6 | everywhere, same topology, IS-IS multi-topology |

### Why BFD matters to this talk

Without it, IS-IS takes ~27 seconds to notice a dead neighbour and BGP
takes 90. With it, sub-second. That is the first question an ISP engineer
will ask about a system that heals in 46 seconds, and the answer has to be
ready:

> BFD reroutes **around** a failure. It does not fix a misconfiguration,
> restore intent, or re-enable an interface somebody shut. Those are what
> the automation does, and no amount of fast convergence substitutes for
> them.

Both belong in the same network. Showing the lab without BFD invites the
conclusion that the automation is solving a problem the protocols already
solved.
