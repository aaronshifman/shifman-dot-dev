---
title: "Dude, Where's My Pod?"
date: 2026-08-06T19:58:00-04:00
draft: false
description: "An adventure in WTF, Cilium?"
tags:
  - kubernetes
  - networking
---

## Preamble

Like any good recipe blog here's a preamble about how my wife's favorite activity is drives in the countryside while mercury is in retrograde and the Dow is above 45432.8 (or whatever stands in for good writing these days).

Most images in my cluster get pulled from a pull-through cache (harbor in this case). There's a whole host of security, resiliency, and observability reasons to do so. But mostly, I think the reason is that adding complexity to my life seems to be my MO. In the last week or so, image pulls have been taking a long time. Harbor is backed by S3 on a very large, and very underpowered NAS so I didn't think _too_ much about it... until I updated an application version and it was pulling a container for well over 20 minutes. The image is a Golang binary the entire image is 8 megabytes... something ain't right.

This is where this gong show begins.

### Something's Broken

To set the stage I've got nodes `worker3` and `worker2` both of which have pods stuck pulling images. So I go take a look at harbor (yes the pull through cache lives in the same cluster that pulls from it, believe it or not; completely unrelated). And I get to see this: hundreds of copies of failing to connect to Redis from the `registry` pod.

```
dial tcp 10.107.65.129:6379: i/o timeout
redis: error connecting: dial tcp 10.107.65.129:6379: i/o timeout  redis.connect.duration=10.001s
```

Irritatingly this isn't tied to the registry pod's health check so pods are marked healthy.

A few thoughts are at the top of mind
1. Is Redis actually working
1. Something's just hung
1. Some labels changed and I missed it and I'm getting hit by `default-deny` network policies dropping packets.

There's a pretty simple litmus test. First, is Redis accepting connections (spoiler, it's fine)
```bash
kubectl exec -n harbor harbor-redis-0 -- redis-cli ping
PONG
```

Option number two, something's just hung. Have you tried turning it off and on again? I go ahead and kill the pods, same issue can't connect to Redis.

Lastly, check Hubble (Cilium's o11y layer) for dropped packets. Check Hubble; no dropped packets. Worse even, explicit allowed flows between registry and Redis. I guess we're going network spelunking.

### Network Topology for Sadists

I could run all my stuff on a couple of VM's and have everything running smoothly. But no, I hate myself.

Everything runs in Kubernetes, that means the "top level" is the Kubernetes overlay network. Again, I hate myself, I have to run a matter server in Kubernetes. This means it's a dual stack cluster (IPv4/IPv6) and it's _only_ been a decade so IPv6 doesn't _just_ work.

This is annoying enough to debug, but I hate myself. Matter needed funky things like masquerading, and Geneve overlays to get working. So this means I can't run something simple like flannel, no, no. Cilium is my torture of choice (not a dig against cilium it's fantastic, but way overkill). But wait, there's more. I have a hybrid setup where some nodes are physical and I have some cloud nodes for extra capacity. As a result all nodes are on a WireGuard network (Tailscale). So if we're counting from the pod layer to effectively layer 2 we have.

- Pod
- Kubernetes overlay network
- Cilium Geneve overlay network
- Tailscale network

And I'm having networking issues in *gestures wildly* this.

#### A quick Cilium primer
Since it's not evidently obvious what Cilium's internals are, there's a couple of internal concepts that'll make things (hopefully) clearer.

**Endpoint**
`CiliumEndpoint` not Kubernetes endpoint. This is Cilium's identifier of a pod's network interface. Cilium compiles a small eBPF program attached to a pod's network interface that does the forwarding and policy decisions

**Identity**
This is Cilium's representation of a pod's identity based on labels. I.e. a set of labels maps to some identifier and routing/policy rules are applied to an identity (as opposed to a pod's IP)


## In Which We Go Spelunking

There's 11 nodes in the cluster and practically everything looks about right but lets rule out some basic things. Can `worker2` talk to the other nodes, `worker2` runs the registry pod and Redis is on `worker1`. Cilium has some pretty good debugging tools so lets start there.

This was run from `worker2`, for brevity in this article I'll exec into a `$NODE` representing the cilium agent pod on the given node
```bash
$ kubectl -n kube-system exec $W2 -c cilium-agent -- cilium-health status
Cluster health:  11/11 reachable
  worker2 (localhost)   2/2   2/2
  worker1               2/2   2/2
  ...
```

To nobody's surprise inter-node connectivity is fine. The next thing to check is, is Cilium sending traffic to the wrong place? We can compare the service map on `worker2` for the Redis ClusterIP (10.107.65.129) against another node (`worker4`, healthy in this context as it has no pull issues with pods)

```
$ kubectl -n kube-system exec $W2 -c cilium-agent -- cilium service list | grep 10.107.65.129
102   10.107.65.129:6379/TCP   ClusterIP   1 => 10.244.190.4:6379 (active)

$ kubectl -n kube-system exec $W4 -c cilium-agent -- cilium service list | grep 10.107.65.129
243   10.107.65.129:6379/TCP   ClusterIP   1 => 10.244.190.4:6379 (active)
```

Both nodes think
1. The same cluster IP routes to the same pod IP
1. The pod is active

This looks about right, and I'm starting to run out of ideas here. A bit of googling and we can check the traffic flows. I'd like to validate that the network policies are letting traffic through (maybe Hubble lied to me) If we first grab Redis' endpoint id (2627)

```bash
$ kubectl -n kube-system exec $W1 -c cilium-agent -- cilium bpf policy get 2627
DIRECTION   IDENTITY/LABELS                                     PORT/PROTO   BYTES      PACKETS
...
Allow  Ingress  k8s:app.kubernetes.io/component=registry ...    6379/TCP     11768590   159035
...
```

Redis explicitly allows the registry on 6379, and the counter shows roughly 160k packets already accepted. So `registry` can communicate with Redis, or at the very least, `registry` can talk _at_ Redis.


### Follow the White ~Rabbit~ Packets

I'm already waist deep into this, why not go deeper ('cmon, rabbit hole, follow the white rabbit... it's funny). We can watch the actual packets between the two pods at the TCP layer, remember 10.244.190.4 is the Redis pod IP

```bash
$ kubectl -n kube-system exec $W1 -c cilium-agent -- cilium monitor -n | grep 10.244.190.4
-> overlay flow ... identity 53256->813 state reply ifindex cilium_geneve  10.244.190.4:6379 -> 10.244.182.26:46596 tcp SYN, ACK
-> overlay flow ... identity 53256->813 state reply ifindex cilium_geneve  10.244.190.4:6379 -> 10.244.182.26:46602 tcp SYN, ACK
```

Redis (identity `53256`) is receiving the SYN and is replying `SYN, ACK`, pushing it out the `cilium_geneve` overlay toward `worker2`. So the client's `SYN` arrives, and Redis answers. We can also watch from the other side, on `worker2`

```bash
$ kubectl -n kube-system exec $W2 -c cilium-agent -- cilium monitor | grep 10.244.190.4
-> overlay ... identity 813->53256 ... 10.244.182.26:41736 -> 10.244.190.4:6379 tcp SYN
-> overlay ... identity 813->53256 ... 10.244.182.26:41718 -> 10.244.190.4:6379 tcp SYN
```

I actually found my missing packets (no sweet clue where they went, but I have the break in the chain). At this point I was contemplating Goose farming so I'll take whatever progress I can get.

Plenty of `SYN` packets to Redis not a single `SYN,ACK` back and weirdly no Cilium drop event either, I know Redis sent the `SYN,ACK` it just evaporated into the ether.

This also shows up in the `conntrack` table

```bash
$ kubectl -n kube-system exec $W2 -c cilium-agent -- cilium bpf ct list global | grep 10.244.190.4
TCP OUT 10.244.182.26:54332 -> 10.244.190.4:6379  Packets=0  RxFlagsSeen=0x00  TxFlagsSeen=0x02
TCP OUT 10.244.182.26:57824 -> 10.244.190.4:6379  Packets=0  RxFlagsSeen=0x00  TxFlagsSeen=0x02
...
```

The reply left `worker1` and evaporated before ever reaching `worker2`. If Cilium isn't dropping it, and it's leaving one node but not arriving at the other, the packet is dying somewhere. So the next guess is its getting lost in the WireGuard abyss.

{{< mermaid >}}
sequenceDiagram
    participant R as registry (worker2)
    participant W as redis (worker1)
    R->>W: SYN (geneve/tailscale)
    Note over W: arrives, policy allows
    W-->>R: SYN,ACK (geneve/tailscale)
    Note over R: never arrives.
{{< /mermaid >}}


### Tailscale Spelunking

I don't have a SIEM setup to send Tailscale flows to (I really should get on that). However, I can once again apply the reboot shaped hammer to my "WTF is going on" shaped nail. I restarted the Tailscale extension on all my nodes validated that
1. The extension comes back healthy
1. Cilium health checks still come back healthy
1. Double check that all nodes have reauthenticated with Tailscale

Then I tried bouncing the Cilium agents cluster-wide. Also didn't fix it (I'll spare the duplication of all the other hopeless polling of Cilium internals).

This is some shoddy debugging work, I did the easy Tailscale debugging, however going deeper would be much harder. I'm comfortable dropping this for now since I have 11 nodes all talking to each other (that's up to 55 WireGuard tunnels). Each node has a suite of different applications, and protocols, doing different things. The idea that its just Redis (ignoring the 15 other Redis pods I'm running) makes it difficult to justify looking for a more systematic Tailscale issue. This narrows the break to Cilium, packets can get to `worker1`, they just can't seem to leave.

### The Packet Is Dead, Long Live the Packet
All I can tell at this point is `worker2` can send packets to Redis but Redis cannot send packets back to `worker2`. I have two last avenues to explore before I find my friendly neighborhood goose, and start my farming journey.

1. It's 1999 and I'm dealing with MTU mismatches?
1. Is anything able to communicate with Redis?

I'll be honest I don't have the will to deal with MTU debugging I'll accept 20 minute image pull times. So communication exploration it is.

What if we try opening a TCP connection to Redis from each node, I'll spare the universe from the bash nonsense I had to mangle together for trying to hit Redis. In short, the only node that could reach Redis is `worker1`, the node that Redis is currently scheduled on. What if I shoot the Redis pod and let it reschedule? It landed on a different node with a new IP

```bash
$ kubectl get pod -n harbor -l component=redis -o wide
harbor-redis-0   Running   10.244.186.254   worker3
```

Now `worker3` can hit Redis but no other node can. So not only is it a packet loss, but it's a cross-node packet loss, that survives pod restarts and reschedules. As far as I know the only other meaningful thing cilium keeps track of at the pod level is its `identity`. Which is stored as a CiliumIdentity CRD, so it's independent of pod restarts (and even Cilium restarts for that matter).
```bash
$ kubectl get ciliumendpoint harbor-redis-0 -n harbor -o jsonpath='{.status.identity.id}'
53256
```

I have no justification but at this point I'm shooting things left right and center at like 11pm trying to sort this out. Here's my working theory, Cilium got out of sorts. What if cilium (the operator) thinks one thing about the identity but the cilium eBPF program thinks something else.

Simple test, I turn off auto reconciliation in argo, and I add a new label to the podTemplate `foo: bar` (I know so original). Redis gets torn down and stands back up (gets a new identity) and what do you know the registry can talk to Redis no problem.

Now if I was smarter, I would've gotten more in depth with this, it would've made a really interesting story I'm sure. However, I was tired and hey the problem was solved (I think). So I clean up the old identity, and roll the cilium node agents.

```bash
kubectl delete ciliumidentity 53256
kubectl -n kube-system rollout restart ds/cilium
```
Turn the reconciliation back on, and things still work.

```
$ kubectl get ciliumendpoint harbor-redis-0 -n harbor -o jsonpath='{.status.identity.id}'
6763
$ kubectl get ciliumidentity 53256
Error from server (NotFound): ciliumidentities.cilium.io "53256" not found
```

Just for funzies I shot a whole bunch of pods across the cluster (odds are some will schedule on new nodes) and yep image pulls are running in a few seconds. Crisis averted.

## Takeaways

- Complexity isn't free
  - Something got borked inside _many_ layers of networking
- If you're an application developer and your application doesn't work without another service, wire it into the damn health probe
- I should probably update Cilium
