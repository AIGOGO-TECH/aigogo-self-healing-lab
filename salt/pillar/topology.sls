# Link-level and session-level intent — the guardrails, not the source of
# truth.
#
# The distinction matters and it changed with the four-node design. NetBox
# holds what the network SHOULD look like. This file holds what automation
# is ALLOWED to do about it: which interfaces may be re-enabled, which MTU
# a link is permitted to be set to, which BGP neighbours may be un-shut.
# A remediation looks its parameters up here rather than taking them from
# the caller, so an LLM -- or anyone else reaching salt-api -- cannot
# smuggle a value through.
#
# Addressing follows docs/addressing.md. Anything here that disagrees with
# clab/gen-configs.py is a bug in one of the two.

# --- point-to-point links -------------------------------------------------
# A link fault is a property of the PAIR, not of either device, which is why
# the p2p_mismatch beacon needs both ends declared and reads the far end
# through the Salt mine.
p2p_links:
  srl1:
    ethernet-1/1: {peer: srl2, peer_interface: ethernet-1/1, mtu: 9232}
    ethernet-1/2: {peer: srl3, peer_interface: ethernet-1/2, mtu: 9232}
  srl2:
    ethernet-1/1: {peer: srl1, peer_interface: ethernet-1/1, mtu: 9232}
    ethernet-1/2: {peer: srl3, peer_interface: ethernet-1/1, mtu: 9232}
  srl3:
    ethernet-1/1: {peer: srl2, peer_interface: ethernet-1/2, mtu: 9232}
    ethernet-1/2: {peer: srl1, peer_interface: ethernet-1/2, mtu: 9232}
    # The transit uplink. Declared so MTU mismatch is still detected, but
    # srl4 is not ours: the mine has no data for it, so p2p_mismatch will
    # skip this link rather than guess. That is the correct behaviour at an
    # administrative boundary and worth showing.
    ethernet-1/3: {peer: srl4, peer_interface: ethernet-1/1, mtu: 9232}

# --- how many IS-IS adjacencies each device must end up with --------------
# golden_config's outcome check. srl3 has three p2p links but only two
# IS-IS neighbours: ethernet-1/3 faces srl4, which runs eBGP and is not
# ours, so no adjacency forms there and none should be expected.
#
# This lives in pillar rather than in the state for the same reason every
# other parameter does: a remediation must not be able to lower the bar it
# is judged against. A caller who could pass expected=0 would turn the
# check into a formality.
isis_adjacencies:
  srl1: 2
  srl2: 2
  srl3: 2

# --- interfaces that must never be administratively down ------------------
# restore_interface refuses any interface not on this list, so the blast
# radius of a wrong decision is bounded by the inventory, not by the model.
monitored_interfaces:
  srl1: [ethernet-1/1, ethernet-1/2]
  srl2: [ethernet-1/1, ethernet-1/2]
  srl3: [ethernet-1/1, ethernet-1/2, ethernet-1/3]

# --- BGP sessions ---------------------------------------------------------
# srl1 and srl2 are both route reflectors in one cluster; srl3 is a client
# of both. Losing either reflector no longer loses the client's routes --
# the three-node design had one RR that was also a transit node.
#
# Sessions ride the loopbacks, so they depend on IS-IS: an IGP fault takes
# BGP with it about a minute later, which is exactly the cascading failure
# operators actually see, and why bgp_down suppresses a session fault while
# an interface fault is open on the same device.
bgp_neighbors:
  srl1:
    10.255.0.2: {role: route-reflector}
    10.255.0.3: {role: rr-client}
  srl2:
    10.255.0.1: {role: route-reflector}
    10.255.0.3: {role: rr-client}
  srl3:
    10.255.0.1: {role: route-reflector}
    10.255.0.2: {role: route-reflector}
    # eBGP to the upstream. A different administrative domain, so the
    # remediation for it is deliberately the same narrow one -- un-shut a
    # session that is declared here -- and nothing more. Automation does
    # not get to renegotiate with a provider.
    198.51.100.0: {role: transit, peer_as: 64500}
